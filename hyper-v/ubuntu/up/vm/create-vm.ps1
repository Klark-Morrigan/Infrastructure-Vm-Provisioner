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

    # Serial-console capture handle, held in a [ref] box. The capture is
    # started inside the 'create + start' sub-step, whose body runs via
    # '& $Action' (a child scope) in Invoke-WithSubStepTimer; a plain
    # variable assigned there would write to that child scope and never
    # reach the wait-for-SSH teardown below. The [ref] is shared across
    # scopes, so the teardown reads $consoleCapture.Value. Declared here
    # so Stop-SerialConsoleCapture still runs when Start-VM threw or the
    # sub-step failed before the capture started. See
    # Invoke-SerialConsoleCapture.ps1.
    $consoleCapture = [ref] $null

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

    # Per-VM diag-folder retention. The diagnostics root for this VM
    # accumulates one timestamped subfolder per run (console.log,
    # cloud-init-*.txt, runtime-diag.log, ssh.log all collocated).
    # Sweep before this run drops its first artifact so the
    # operator's disk does not grow without bound across repeated
    # provisions. The age pass runs first: keep only runs from the
    # last 7 days, then cap at the 30 most recent of those so a burst
    # of rapid re-provisions within the window still cannot grow the
    # folder without bound. 7 days is the load-bearing limit; MaxItems
    # is the burst backstop.
    if ($Vm.PSObject.Properties['vmConfigPath'] -and $Vm.vmConfigPath) {
        $perVmDiagRoot = Join-Path (Join-Path $Vm.vmConfigPath 'diagnostics') `
                                   $Vm.vmName
        Limit-RetainedItem -Directory  $perVmDiagRoot `
                           -Filter     '????-??-??_*' `
                           -MaxItems   30 `
                           -MaxAgeDays 7
    }

    $consoleCapture.Value = Start-SerialConsoleCapture `
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

    # Router VMs in externalDhcp mode (an opt-in for bridged External
    # switches; static is the default) have no ipAddress in their VM def
    # at this point - the upstream NIC's address gets handed to them by
    # the LAN's DHCP server moments after boot. NOTE: DHCP mode is
    # unvalidated - see the dhcp-unfinished TODO in Assert-RouterVmField's
    # externalDhcp note. Discover it through Hyper-V's KVP integration
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
    # _RouterVm onto every workload def; Wait-VmSshAccessible opens a
    # port forward through that router and probes the loopback endpoint
    # that emerges at the workload on the far side of the jump. Router
    # VMs (and any pre-feature-53 caller) take the no-router branch and
    # the helper probes the configured IP directly. Presence of a router
    # def is what selects the tunnelled path; Wait-VmSshAccessible owns
    # the tunnel lifecycle (open and dispose).
    $hasRouter = $Vm.PSObject.Properties['_RouterVm'] -and $Vm._RouterVm
    $routerVm  = if ($hasRouter) { $Vm._RouterVm } else { $null }

    # Router-side reachability gate, handed to Wait-VmSshAccessible as its
    # -OnTunnelOpened seam so it runs against the helper-owned tunnel's
    # JumpClient after the forward opens and before the banner poll.
    # Workloads only; on the router branch $onTunnelOpened is $null and the
    # helper goes straight to the direct banner poll. The gate owns the
    # router-side probe plus its diag bundle on failure (see
    # common\network\Assert-WorkloadReachableViaRouter.ps1). A throw here
    # propagates out of the helper, whose finally disposes the forward,
    # and then hits create-vm's own finally below (serial-console +
    # seed-ISO cleanup). Closes over $Vm via .GetNewClosure() so the gate
    # body resolves the VM def regardless of the session state the helper
    # invokes it from.
    $onTunnelOpened = $null
    if ($hasRouter) {
        $onTunnelOpened = {
            param($tunnel)

            $diagFolder = Get-VmDiagFolder -VmConfigPath $Vm.vmConfigPath `
                                           -VmName       $Vm.vmName `
                                           -Timestamp    $Vm._diagTimestamp
            # Hyper-V VM-state check is the caller's concern; the gate
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
            try {
                Assert-WorkloadReachableViaRouter `
                    -JumpClient      $tunnel.JumpClient `
                    -WorkloadIp      $Vm.ipAddress `
                    -WorkloadVmName  $Vm.vmName `
                    -RouterVmName    $Vm._RouterVm.vmName `
                    -DiagFolder      $diagFolder `
                    -OnPoll          $gateOnPoll
            } catch {
                # Output ordering: end the unterminated dot line,
                # surface the actual error message, THEN fire the
                # diag. Without these the dots run into the diag-log
                # path on the same line, and the error appears later
                # in the timing report instead of right above the
                # diag pointer.
                Write-Host ''
                Write-Host ('  [ERROR] ' + $_.Exception.Message) `
                    -ForegroundColor Red
                # Same host+guest snapshot as the wait-for-SSH path.
                # Assert-WorkloadReachableViaRouter already writes its
                # own router-side-probe.log into $diagFolder; this adds
                # the host-side network truth + (if SSH opens) the
                # workload's own runtime state, both of which the
                # router-side probe alone cannot see.
                try {
                    Invoke-VmRuntimeDiag -Vm           $Vm `
                                         -VmConfigPath $Vm.vmConfigPath `
                                         -Timestamp    $Vm._diagTimestamp |
                        Out-Null
                } catch {
                    Write-Host "  [diag] runtime-diag capture failed: $($_.Exception.Message)" `
                        -ForegroundColor Yellow
                }
                throw
            }

            # Print the banner-poll label as the gate's last act so it
            # lands on a fresh line right after the gate's own output
            # block and immediately before the helper starts the banner
            # dots. The router branch prints the identical label before
            # the helper call (no preceding gate output to clear) - see
            # the matching Write-Host below.
            Write-Host "  Polling SSH on $($Vm.vmName) ..." -NoNewline
        }.GetNewClosure()
    }

    # The Hyper-V "VM no longer Running" early-exit, forwarded to the
    # helper as -OnPoll and on to Wait-VmSshBannerReachable. The callback
    # closes over a plain string ($vmName) instead of $Vm.vmName so we are
    # not dependent on .GetNewClosure() capturing a PSCustomObject -
    # callbacks invoked from a different module/session state see the
    # script-block-local string the same way regardless.
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

    try {
        # Router / standalone branch has no -OnTunnelOpened gate, so the
        # banner-poll label is printed here, right before the helper
        # starts the banner dots. The workload branch prints the same
        # label at the tail of -OnTunnelOpened instead, so the gate's
        # output block lands first.
        if (-not $hasRouter) {
            Write-Host "  Polling SSH on $($Vm.vmName) ..." -NoNewline
        }

        # Wait-VmSshAccessible is the single source of truth for
        # "SSH-accessible": it picks the probe endpoint for the VM kind
        # (tunnel loopback for a workload, the VM IP on :22 for a router),
        # drives Wait-VmSshBannerReachable against it until $deadline,
        # fires the router-side gate via -OnTunnelOpened, and disposes any
        # tunnel it opened in its own finally. It returns a result object
        # rather than throwing on timeout, so the create-vm-specific
        # timeout diag + throw below is keyed on $result.Reachable.
        $result = Wait-VmSshAccessible `
                      -Vm                  $Vm `
                      -RouterVm            $routerVm `
                      -Deadline            $deadline `
                      -PollIntervalSeconds $pollIntervalSeconds `
                      -OnPoll              $onPollVmState `
                      -OnTunnelOpened      $onTunnelOpened
        $sshReady = $result.Reachable

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
            # Headline error first so the operator sees it before the
            # diag log path - mirrors the router-side reachability
            # catch above for output consistency. The Format-Elapsed
            # gradient line above already terminated the dot line.
            $sshTimeoutMessage = (
                "SSH on '$($Vm.vmName)' did not become reachable within " +
                "$timeoutMinutes minutes. Check the Hyper-V console for " +
                "boot errors."
            )
            Write-Host ('  [ERROR] ' + $sshTimeoutMessage) `
                -ForegroundColor Red

            # Capture host-side networking truth before throwing.
            # This is exactly the diag we hand-ran for the WiFi-MAC
            # collision and ICS DHCP-drift cases: side-by-side
            # Get-VMNetworkAdapter / Get-NetNeighbor / arp -a / route
            # tables make duplicate or drifted IPs obvious at a glance.
            # Guest-side capture is best-effort - if SSH happens to
            # work post-timeout we get a bonus inside-VM dump; if not,
            # we still have the host-side log. Wrapped in try/catch so
            # a diag failure does not mask the headline timeout.
            try {
                Invoke-VmRuntimeDiag -Vm           $Vm `
                                     -VmConfigPath $Vm.vmConfigPath `
                                     -Timestamp    $Vm._diagTimestamp |
                    Out-Null
            } catch {
                Write-Host "  [diag] runtime-diag capture failed: $($_.Exception.Message)" `
                    -ForegroundColor Yellow
            }
            throw $sshTimeoutMessage
        }

        # Banner-reachable proves sshd answers, NOT that a usable login
        # exists. A router is probed directly (no tunnel) and is the jump
        # host every workload authenticates through moments later, so a
        # failed cloud-init user creation here (e.g. a base-image-missing
        # supplementary group aborting useradd) must fail loudly NOW with a
        # named cause, instead of resurfacing as an opaque "Permission
        # denied (password)" on the first workload's tunnel. Workload VMs
        # skip this gate: their own post-provisioning session authenticates
        # and would surface the same fault directly against the workload.
        $isRouterVm = $Vm.PSObject.Properties['kind'] -and $Vm.kind -eq 'router'
        if ($isRouterVm) {
            $routerDiagFolder = Get-VmDiagFolder `
                                    -VmConfigPath $Vm.vmConfigPath `
                                    -VmName       $Vm.vmName `
                                    -Timestamp    $Vm._diagTimestamp
            Assert-VmSshCredentialsAccepted `
                -IpAddress      $Vm.ipAddress `
                -Username       $Vm.username `
                -Password       $Vm.password `
                -VmName         $Vm.vmName `
                -ConsoleLogPath (Join-Path $routerDiagFolder 'console.log')
        }

        Write-Host "  [OK] SSH reachable on $($Vm.vmName)." -ForegroundColor Green
    }
    finally {
        # Wait-VmSshAccessible owns any SSH tunnel and disposes it before
        # returning, so by here there is no forward left to tear down -
        # this block only stops the serial-console reader and removes the
        # seed ISO.
        #
        # Stop the serial-console reader. Safe to call with $null (Start
        # may have thrown). The reader normally exits on its own when the
        # VM stops; this is belt-and-braces for the orchestrator-tears-
        # down-first case.
        Stop-SerialConsoleCapture -Capture $consoleCapture.Value

        Remove-VmSeedIso -VmName $Vm.vmName -SeedIsoPath $Vm._seedIsoPath
    }

        } # end 'wait for SSH' sub-step

    Write-Host "  [OK] $($Vm.vmName) ready." -ForegroundColor Green
    Write-Host "    Connect: ssh $($Vm.username)@$($Vm.vmName)" `
        -ForegroundColor Cyan
}
