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
        # Router-side reachability gate. Owns the polling probe plus
        # the diag bundle capture on failure - see
        # common\network\Assert-WorkloadReachableViaRouter.ps1 for
        # the full contract. Lives inside the try block so a gate
        # throw still disposes the tunnel + serial console capture
        # via the finally below.
        if ($hasRouter) {
            $diagFolder = Get-VmDiagFolder -VmConfigPath $Vm.vmConfigPath `
                                           -VmName       $Vm.vmName `
                                           -Timestamp    $Vm._diagTimestamp
            # Hyper-V VM-state check is the caller's concern; the
            # helper stays generic. A non-Running state means the
            # workload crashed / shut itself off before its sshd could
            # come up - no point waiting out the gate's full budget.
            # Closes over a plain string ($vmName) so the callback
            # works regardless of which module/session state the
            # helper invokes it from.
            $vmName     = $Vm.vmName
            $gateOnPoll = {
                $vmState = (Get-VM -Name $vmName).State
                if ($vmState -ne 'Running') {
                    throw (
                        "VM '$vmName' stopped unexpectedly " +
                        "(state: $vmState) during router-side probe."
                    )
                }
            }.GetNewClosure()
            Assert-WorkloadReachableViaRouter `
                -JumpClient      $sshTunnel.JumpClient `
                -WorkloadIp      $Vm.ipAddress `
                -WorkloadVmName  $Vm.vmName `
                -RouterVmName    $Vm._RouterVm.vmName `
                -DiagFolder      $diagFolder `
                -OnPoll          $gateOnPoll
        }

        Write-Host "  Polling SSH on $($Vm.vmName) ..." -NoNewline

        # Wait-VmSshBannerReachable owns the TCP+banner gate and the
        # progress-dot cadence; the OnPoll callback below carries the
        # Hyper-V "VM no longer Running" early-exit check that does not
        # belong in a generic SSH waiter. The callback closes over a
        # plain string ($vmName) instead of $Vm.vmName so we are not
        # dependent on .GetNewClosure() capturing a PSCustomObject -
        # callbacks invoked from a different module/session state see
        # the script-block-local string the same way regardless.
        $vmName = $Vm.vmName
        $onPollVmState = {
            $vmState = (Get-VM -Name $vmName).State
            if ($vmState -ne 'Running') {
                Write-Host ''
                throw (
                    "VM '$vmName' stopped unexpectedly " +
                    "(state: $vmState). Check the Hyper-V console."
                )
            }
        }.GetNewClosure()
        $sshReady = Wait-VmSshBannerReachable `
                        -IpAddress           $probeIp `
                        -Port                $probePort `
                        -Deadline            $deadline `
                        -PollIntervalSeconds $pollIntervalSeconds `
                        -OnPoll              $onPollVmState

        # Elapsed-time tail on the same line as the dots. Outcome-
        # encoded gradient lives in Format-ElapsedBudgetWithGradient.
        $totalSeconds = $timeoutMinutes * 60
        $elapsedSecs  = [int]([Math]::Round(
            ((Get-Date) - $startTime).TotalSeconds))
        Write-Host (' ' + (Format-ElapsedBudgetWithGradient `
                              -ElapsedSeconds $elapsedSecs `
                              -BudgetSeconds  $totalSeconds `
                              -Succeeded      $sshReady))

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

        Remove-VmSeedIso -VmName $Vm.vmName -SeedIsoPath $Vm._seedIsoPath
    }

        } # end 'wait for SSH' sub-step

    Write-Host "  [OK] $($Vm.vmName) ready." -ForegroundColor Green
    Write-Host "    Connect: ssh $($Vm.username)@$($Vm.vmName)" `
        -ForegroundColor Cyan
}
