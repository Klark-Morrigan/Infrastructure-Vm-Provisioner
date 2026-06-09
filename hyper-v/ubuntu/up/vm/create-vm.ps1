<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1 after acquire-disk-image.ps1 and generate-seed-iso.ps1
    have run (Vm._vhdxPath and Vm._seedIsoPath must be set).
#>

# ---------------------------------------------------------------------------
# Invoke-VmCreation
#   Creates a Hyper-V Gen 2 VM, boots it, waits for SSH to become reachable,
#   then removes the seed ISO.
#
#   Steps performed:
#     1. Create the VM with Gen 2, static RAM, and the per-VM VHDX.
#     2. Set CPU count.
#     3. Configure Secure Boot with the UEFI CA template (required for
#        Ubuntu's shim bootloader).
#     4. Attach the seed ISO as a DVD drive (cloud-init reads it on boot).
#     5. Connect the network adapter to the shared Internal switch.
#     6. Start the VM.
#     7. Poll TCP port 22 until cloud-init finishes (SSH reachable = done).
#     8. Detach and delete the seed ISO in a finally block so it is always
#        removed regardless of SSH success or timeout (it contains the
#        plaintext password).
# ---------------------------------------------------------------------------
function Invoke-VmCreation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Vm,

        [Parameter(Mandatory)]
        [string] $SwitchName
    )

    Write-Host ""
    Write-Host "--- Creating VM: $($Vm.vmName) ---" -ForegroundColor Cyan

    # Serial-console capture handle. Declared at function scope so the
    # wait-for-SSH finally block can call Stop-SerialConsoleCapture even
    # when Start-VM threw or the 'create + start' sub-step fails. See
    # Invoke-SerialConsoleCapture.ps1.
    $consoleCapture = $null

    # Phase split: 'create + start' covers everything up to and including
    # Start-VM (Hyper-V API work, typically sub-second). 'wait for SSH'
    # covers the subsequent polling loop, which is guest-boot dominated
    # (typically 30-90 s on first boot with cloud-init). Separating
    # these two clarifies whether a slow run is a Hyper-V issue or a
    # guest-boot issue.
    Invoke-WithSubStepTimer `
        -Parent 'VM creation' `
        -Name   'create + start' `
        -Action {

    # -Path directs Hyper-V to store the VM configuration files (.vmcx etc.)
    # in vmConfigPath, keeping them co-located with the seed ISO and separate
    # from the OS disk in vhdPath.
    # MemoryStartupBytes is static RAM - dynamic memory is not used because
    # runner workloads benefit from a predictable allocation and dynamic
    # memory adds balloon-driver overhead inside the guest.
    Write-Host "  Creating VM (Gen 2, $($Vm.cpuCount) vCPU, $($Vm.ramGB) GB RAM) ..."
    New-VM -Name              $Vm.vmName `
           -Generation        2 `
           -MemoryStartupBytes ([int64]$Vm.ramGB * 1GB) `
           -VHDPath           $Vm._vhdxPath `
           -Path              $Vm.vmConfigPath | Out-Null

    # ------------------------------------------------------------------
    # Verify New-VM produced a VM in the Off state before proceeding.
    # If the VHDX was locked by a still-running previous instance, New-VM
    # may have silently failed while $ErrorActionPreference = 'Stop' did
    # not fire (Hyper-V can surface some failures as warnings). A host
    # auto-start policy could also start the VM between creation and here.
    # Both cases would cause Set-VMFirmware to fail with "cannot modify
    # firmware while VM is running". We catch both by checking state now
    # and throwing a clear message rather than a confusing firmware error.
    # ------------------------------------------------------------------
    $createdVmState = (Get-VM -Name $Vm.vmName -ErrorAction Stop).State
    if ($createdVmState -ne 'Off') {
        throw (
            "VM '$($Vm.vmName)' is in state '$createdVmState' immediately " +
            "after creation - expected 'Off'. A previous provisioning run " +
            "may have left it running. Stop or remove the VM manually and " +
            "re-run, or delete the per-VM disk to force a fresh provision."
        )
    }

    Set-VMProcessor -VMName $Vm.vmName -Count $Vm.cpuCount

    # ------------------------------------------------------------------
    # Secure Boot
    # The default template 'MicrosoftWindows' rejects Ubuntu's shim
    # bootloader. 'MicrosoftUEFICertificateAuthority' trusts third-party
    # UEFI bootloaders signed by Microsoft, which Ubuntu's shim is.
    # Setting the first boot device to the VHDX avoids a PXE network-boot
    # attempt that would add a timeout before every boot.
    # ------------------------------------------------------------------
    $osDisk = Get-VMHardDiskDrive -VMName $Vm.vmName | Select-Object -First 1
    Set-VMFirmware -VMName              $Vm.vmName `
                   -EnableSecureBoot    On `
                   -SecureBootTemplate  'MicrosoftUEFICertificateAuthority' `
                   -FirstBootDevice     $osDisk

    # ------------------------------------------------------------------
    # Seed ISO
    # Attached as a DVD drive. cloud-init does not require the ISO to be
    # bootable - the NoCloud datasource scans all block devices for a
    # volume labelled 'cidata'. The DVD drive sits below the VHDX in the
    # boot order and is never attempted as a boot source.
    # ------------------------------------------------------------------
    Add-VMDvdDrive -VMName $Vm.vmName -Path $Vm._seedIsoPath

    # ------------------------------------------------------------------
    # Network
    #
    # Workload VMs get one NIC on $SwitchName (caller's choice). Router
    # VMs (kind: router) get a second NIC on their privateSwitchName
    # and both NICs are pinned to deterministic MACs so the cloud-init
    # netplan's match-by-MAC blocks find their NIC. See feature 53.
    # ------------------------------------------------------------------
    Connect-VMNetworkAdapter -VMName     $Vm.vmName `
                             -Name       'Network Adapter' `
                             -SwitchName $SwitchName

    $kind = if ($Vm.PSObject.Properties['kind']) { $Vm.kind } else { 'workload' }
    if ($kind -eq 'router') {
        # Pin the default NIC's MAC to the same value the router seed
        # embedded in its netplan match block. Without this Hyper-V's
        # dynamic-MAC pool would hand the guest a different MAC each
        # boot and netplan would never bring the interface up.
        Set-VMNetworkAdapter -VMName           $Vm.vmName `
                             -Name             'Network Adapter' `
                             -StaticMacAddress $Vm._externalMac

        # Add the private-side NIC. Name 'Private' is chosen so Get-
        # VMNetworkAdapter / operator inspection at the Hyper-V layer
        # immediately distinguishes the two adapters.
        Add-VMNetworkAdapter -VMName           $Vm.vmName `
                             -Name             'Private' `
                             -SwitchName       $Vm.privateSwitchName `
                             -StaticMacAddress $Vm._privateMac
    }

    # Attach the named-pipe serial reader BEFORE Start-VM so we do not
    # miss the early kernel / cloud-init lines. The reader job sits on
    # Connect() until Hyper-V publishes the pipe (which happens as the
    # VM starts).
    #
    # _diagTimestamp is set here so Invoke-CloudInitDiagnostics (which
    # runs later in post-provisioning) writes into the SAME
    # diagnostics/<vmName>/<timestamp>/ folder as console.log. Both
    # diagnostic functions read this field.
    $diagTimestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    Add-Member -InputObject $Vm -MemberType NoteProperty `
               -Name '_diagTimestamp' -Value $diagTimestamp -Force

    $consoleCapture = Start-SerialConsoleCapture `
                          -VmName       $Vm.vmName `
                          -VmConfigPath $Vm.vmConfigPath `
                          -Timestamp    $diagTimestamp

    Write-Host "  Starting VM ..."
    Start-VM -VMName $Vm.vmName
    Write-Host "  [OK] VM started." -ForegroundColor Green

        } # end 'create + start' sub-step

    # ------------------------------------------------------------------
    # Poll port 22 until cloud-init finishes, then delete seed ISO.
    #
    # cloud-init runs on first boot: applies netplan (static IP), installs
    # openssh-server, and creates the OS user. SSH becoming reachable is
    # the reliable completion signal - it requires all of the above to have
    # succeeded.
    #
    # The seed ISO is deleted in a finally block so it is removed regardless
    # of whether SSH succeeds or times out. cloud-init reads all seed files
    # into /var/lib/cloud/ at the very start of its run; by the time any
    # timeout fires the ISO is no longer read and is safe to delete.
    # Leaving it on disk is never acceptable - it contains the plaintext
    # password.
    #
    # The outer loop is kept inline (rather than calling Wait-VmSshReady)
    # because each iteration also checks Get-VM state - a Hyper-V cmdlet
    # concern that does not belong in a generic SSH helper. The TCP probe
    # itself is delegated to Test-VmSshPort.
    # ------------------------------------------------------------------
    $timeoutMinutes      = 10
    $pollIntervalSeconds = 10
    $startTime           = Get-Date
    $deadline            = $startTime.AddMinutes($timeoutMinutes)
    $sshReady            = $false

    Invoke-WithSubStepTimer `
        -Parent 'VM creation' `
        -Name   'wait for SSH' `
        -Action {

    # Router VMs in externalDhcp mode (the schema default) have no
    # ipAddress in their VM def at this point - the upstream NIC's
    # address gets handed to them by the LAN's DHCP server moments
    # after boot. Discover it through Hyper-V's KVP integration
    # services BEFORE the SSH probe: poll Get-VMNetworkAdapter on
    # the external switch until an IPv4 appears, then write it back
    # onto $Vm.ipAddress so every downstream consumer (this loop's
    # SSH probe, the workload's tunnel in step 7, plan/diag output)
    # sees a single source of truth. Pinned-static router VMs and
    # workload VMs already have ipAddress and skip the discovery
    # loop.
    $needsIpDiscovery = -not $Vm.PSObject.Properties['ipAddress']
    if ($needsIpDiscovery) {
        # Get-VmKvpIpAddress (Infrastructure.HyperV >= 0.11.0) owns the
        # polling loop, the VM-state guard, the IPv4 filter, and the
        # deadline error surface. -OnPoll paints the inline progress
        # dot so the operator sees the discovery is alive without the
        # helper having to know about Write-Host. The discovered IP is
        # stamped back onto $Vm so downstream consumers (this loop's
        # SSH probe, the workload tunnel below) see a single source of
        # truth.
        Write-Host "  Discovering ext0 IP via Hyper-V KVP ..." -NoNewline
        try {
            $discoveredIp = Get-VmKvpIpAddress `
                                -VmName              $Vm.vmName `
                                -SwitchName          $Vm.externalSwitchName `
                                -TimeoutMinutes      $timeoutMinutes `
                                -PollIntervalSeconds $pollIntervalSeconds `
                                -OnPoll              { Write-Host '.' -NoNewline }
        } catch {
            Write-Host ''
            throw
        }

        Add-Member -InputObject $Vm `
                   -MemberType NoteProperty `
                   -Name 'ipAddress' `
                   -Value $discoveredIp `
                   -Force
        Write-Host " $discoveredIp" -ForegroundColor Green
    }

    # Workload VMs after feature 53 sit on a per-environment private
    # switch the host has no route to. provision.ps1 step 7 stamps
    # _RouterVm onto every workload def; we open a port forward
    # through that router so the TCP probe below can target a
    # localhost endpoint that emerges at the workload on the far
    # side of the jump. Router VMs (and any pre-feature-53 caller)
    # take the no-tunnel branch and probe the configured IP
    # directly.
    $sshTunnel = $null
    $hasRouter = $Vm.PSObject.Properties['_RouterVm'] -and $Vm._RouterVm
    if ($hasRouter) {
        $sshTunnel = New-VmSshTunnel `
                         -TargetIp     $Vm.ipAddress `
                         -JumpHostIp   $Vm._RouterVm.ipAddress `
                         -JumpUsername $Vm._RouterVm.username `
                         -JumpPassword $Vm._RouterVm.password
        $probeIp   = $sshTunnel.LocalHost
        $probePort = $sshTunnel.LocalPort
    } else {
        $probeIp   = $Vm.ipAddress
        $probePort = 22
    }

    try {
        Write-Host "  Polling SSH on $($Vm.vmName) ..." -NoNewline

        while ((Get-Date) -lt $deadline) {
            # Abort early if the VM is no longer running - no point waiting
            # out the full timeout if it has already crashed or shut down.
            $vmState = (Get-VM -Name $Vm.vmName).State
            if ($vmState -ne 'Running') {
                Write-Host ''
                throw (
                    "VM '$($Vm.vmName)' stopped unexpectedly " +
                    "(state: $vmState). Check the Hyper-V console."
                )
            }

            if (Test-VmSshPort -IpAddress $probeIp -Port $probePort) {
                # Through a tunnel, TCP accepts the moment SSH.NET's
                # ForwardedPortLocal listener binds - true says nothing
                # about the workload's own sshd. Banner-read confirms
                # the far end is actually serving SSH so the next
                # consumer (Invoke-VmPostProvisioning's SSH connect)
                # does not race against a still-booting workload and
                # die with "no SSH identification string". Direct
                # probes against a known-good IP take the same banner
                # check uniformly; the cost is one extra round trip
                # per success.
                if (Test-SshBanner -IpAddress $probeIp -Port $probePort) {
                    $sshReady = $true
                    break
                }
            }

            Write-Host '.' -NoNewline
            Start-Sleep -Seconds $pollIntervalSeconds
        }

        # Elapsed-time tail on the same line as the dots. Colour
        # encodes outcome at a glance:
        #   - Success: elapsed shifts green -> orange as the ratio
        #     to the budget climbs. The budget itself is uncoloured
        #     because we did not hit it; colouring it would compete
        #     with the gradient for the eye.
        #   - Timeout: BOTH numbers go red. Elapsed because that
        #     is the time we burned; budget because that is what
        #     we ran out of. Two reds carry the "we hit the cap"
        #     reading from a metre away.
        $totalSeconds = $timeoutMinutes * 60
        $elapsedSecs  = [int]([Math]::Round(
            ((Get-Date) - $startTime).TotalSeconds))
        if ($sshReady) {
            $ratio = [Math]::Min(1.0,
                [double]$elapsedSecs / [double]$totalSeconds)
            # Linear blend (80,200,80) -> (255,165,0): green at ratio 0,
            # orange at ratio 1.
            $r = [int][Math]::Round( 80 + $ratio * (255 -  80))
            $g = [int][Math]::Round(200 + $ratio * (165 - 200))
            $b = [int][Math]::Round( 80 + $ratio * (  0 -  80))
            $elapsedColored = "`e[38;2;$r;$g;${b}m${elapsedSecs}s`e[0m"
            $timeoutColored = "${totalSeconds}s"
        }
        else {
            $red            = '38;2;220;70;70'
            $elapsedColored = "`e[${red}m${elapsedSecs}s`e[0m"
            $timeoutColored = "`e[${red}m${totalSeconds}s`e[0m"
        }
        Write-Host " $elapsedColored / $timeoutColored"

        if (-not $sshReady) {
            throw (
                "SSH on '$($Vm.vmName)' did not become reachable within " +
                "$timeoutMinutes minutes. Check the Hyper-V console for " +
                "boot errors."
            )
        }

        Write-Host "  [OK] SSH reachable on $($Vm.vmName)." -ForegroundColor Green
    }
    finally {
        # Tear the tunnel down before the seed-ISO cleanup so the
        # forward stops listening before the wider 'wait for SSH'
        # sub-step ends. Tunnel disposal is idempotent and safe to
        # call when the tunnel was never opened (router branch).
        if ($null -ne $sshTunnel) { $sshTunnel.Dispose() }

        # Stop the serial-console reader. Safe to call with $null (Start
        # may have thrown). The reader normally exits on its own when the
        # VM stops; this is belt-and-braces for the orchestrator-tears-
        # down-first case.
        Stop-SerialConsoleCapture -Capture $consoleCapture

        # Remove-VMDvdDrive detaches before Remove-Item deletes - deleting a
        # file still attached leaves a broken DVD drive reference in the VM.
        $dvdDrive = Get-VMDvdDrive -VMName $Vm.vmName |
            Where-Object { $_.Path -eq $Vm._seedIsoPath }
        if ($null -ne $dvdDrive) {
            Remove-VMDvdDrive -VMName            $Vm.vmName `
                              -ControllerNumber   $dvdDrive.ControllerNumber `
                              -ControllerLocation $dvdDrive.ControllerLocation
        }
        if (Test-Path $Vm._seedIsoPath) {
            Remove-Item -Path $Vm._seedIsoPath -Force
            Write-Host "  [OK] Seed ISO removed." -ForegroundColor Green
        }
    }

        } # end 'wait for SSH' sub-step

    Write-Host "  [OK] $($Vm.vmName) ready." -ForegroundColor Green
    Write-Host "    Connect: ssh $($Vm.username)@$($Vm.vmName)" `
        -ForegroundColor Cyan
}
