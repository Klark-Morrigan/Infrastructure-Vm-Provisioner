<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1 after the
    per-step functions and Infrastructure.HyperV are loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-VmPostProvisioning
#   Post-provisioning orchestrator. Runs once per VM after Invoke-VmCreation
#   has confirmed SSH is reachable. Owns the transport: opens the host file
#   server and a single SSH session, waits for cloud-init to finish, then
#   dispatches to per-step functions.
#
#   Each dispatched step is self-contained - its inputs come from the VM
#   definition and its own acquired/staged files; it must not consume files
#   left on the VM by another step. Order between steps is therefore a
#   stylistic choice ('files' before installs), not a correctness one.
#
#   Why one orchestrator: starting a file server, opening SSH, and waiting
#   for cloud-init are per-VM concerns paid once, not per-step. Adding a
#   new step adds one dispatch line here, not a fresh file-server +
#   SSH + cloud-init scaffold.
# ---------------------------------------------------------------------------

function Invoke-VmPostProvisioning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Vm
    )

    # Decide which steps apply before opening any transport. If nothing
    # applies, exit silently - no file server, no SSH, no log noise.
    $hasFiles   = $Vm.PSObject.Properties['files'] -and
                  @($Vm.files).Count -gt 0
    # javaDevKit is reconciler-owned: presence of the field is enough to
    # warrant opening the transport even when the operator's intent is
    # "ensure none installed" (javaDevKit: null / []). The reconciler
    # decides install vs uninstall from the desired/installed diff; this
    # gate just decides whether to pay the SSH cost at all.
    $hasJdk     = $Vm.PSObject.Properties['javaDevKit']
    # Gate on field presence (not entries.Count): `entries: []` is the
    # operator's explicit "remove the managed block" intent, so it must
    # still route through to the transport.
    $hasEnvVars = $Vm.PSObject.Properties['envVars']
    # Router VMs MUST run post-provisioning even with no opt-in fields:
    # Assert-RouterServicesActive (below) is the fail-fast gate for
    # nftables / dnsmasq service state, and the cloud-init wait gives
    # those services time to bind interfaces before the check fires.
    # Without this branch, router VMs short-circuit out and a dead
    # dnsmasq is only caught later by the E2E assertion phase.
    $isRouter   = $Vm.PSObject.Properties['kind'] -and
                  $Vm.kind -eq 'router'
    if (-not ($hasFiles -or $hasJdk -or $hasEnvVars -or $isRouter)) {
        return
    }

    Write-Host ""
    Write-Host "--- Post-provisioning: $($Vm.vmName) ---" -ForegroundColor Cyan

    # Ensure $Vm._diagTimestamp is set. Normally populated by
    # Invoke-VmCreation alongside the serial-console capture, but the
    # reconcile path on an existing VM skips creation entirely, so we
    # fall back to Get-Date here. Either way Invoke-CloudInitDiagnostics
    # below uses the same value, keeping the diag dump and console.log
    # for any given provisioning run under one folder.
    if (-not $Vm.PSObject.Properties['_diagTimestamp']) {
        Add-Member -InputObject $Vm -MemberType NoteProperty `
                   -Name '_diagTimestamp' `
                   -Value (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss') -Force
    }

    # Capture VM fields explicitly into locals so the closure scriptblock
    # below sees them when invoked from another module (Invoke-WithVmFileServer
    # lives in Infrastructure.HyperV - function-scoped variables are not in
    # its lookup chain at invocation time without GetNewClosure()).
    # username / password are read off $vmRef inside the closure now
    # that New-VmSshClientWithJump is the connect path, so they no
    # longer need their own locals.
    $vmIp     = $Vm.ipAddress
    $vmName   = $Vm.vmName
    $vmRef    = $Vm
    # vmConfigPath is the diagnostic-output root. PSObject.Properties
    # guard because the reconcile path on an existing VM (and unit
    # tests that build a minimal VM object) may not populate it;
    # StrictMode turns bare access into PropertyNotFound.
    $vmConfigPath               = if ($Vm.PSObject.Properties['vmConfigPath']) {
        $Vm.vmConfigPath
    } else { $null }
    $invokeCloudInitDiagnostics  = ${function:Invoke-CloudInitDiagnostics}
    # Cloud-init poll-with-progress wait. Captured as a closure local
    # for the same scope reason as the other per-step functions; lives
    # in its own file (Wait-CloudInitFinished.ps1) so the polling
    # loop, parse, and budget logic is independently testable.
    $waitCloudInitFinished       = ${function:Wait-CloudInitFinished}
    # Router-only post-cloud-init service check. Captured by the
    # closure below for the same scope reason as the other per-step
    # functions; the call is gated on $vmRef.kind -eq 'router' so
    # workload VMs skip it.
    $assertRouterServicesActive  = ${function:Assert-RouterServicesActive}

    # Capture the per-step functions as scriptblock locals so the closure
    # below can invoke them via the call operator. Name-based command
    # resolution from a closure invoked across a module boundary does NOT
    # walk back into provision.ps1's script scope where these functions
    # were dot-sourced. Capturing as variables sidesteps the lookup
    # entirely - the variables themselves are preserved by GetNewClosure().
    # Module-exported cmdlets (e.g. Copy-VmFiles) work the same way under
    # this approach, so the dispatch is uniform.
    $setEnvironmentVariables = ${function:Set-EnvironmentVariables}
    # Files-dispatch helper. Captured as a closure local so the
    # orchestrator's closure can invoke it across the module
    # boundary; lives in its own file (Invoke-VmFilesDispatch.ps1)
    # so the single-vs-bulk routing + optional-flag defaults are
    # independently testable. Copy-VmFiles / Copy-VmFilesByPattern
    # are now resolved by Invoke-VmFilesDispatch itself - the
    # orchestrator no longer captures them.
    $invokeVmFilesDispatch   = ${function:Invoke-VmFilesDispatch}
    # Reconciler entry points - same capture pattern as the per-step
    # functions above for the same reason (closure does not see
    # provision.ps1's script scope at invocation time).
    $initManifestStore       = ${function:Initialize-VmManifestStore}
    $getProviders            = ${function:Get-Providers}
    $invokeReconciliation    = ${function:Invoke-ToolchainReconciliation}
    # Sub-step timing helpers. Same closure-capture reason as above:
    # the post-block runs inside Invoke-WithVmFileServer's module
    # scope, where bare-name resolution does not walk back into
    # provision.ps1's scope. The post-provisioning phase accumulates
    # each sub-step's wall-clock across every VM in the per-VM loop.
    $invokeWithSubStepTimer  = ${function:Invoke-WithSubStepTimer}
    $addSubStepDuration      = ${function:Add-SubStepDuration}
    # Wraps the real SshClient with a tee-to-file logger covering the
    # whole post-provisioning phase. See New-DiagnosticSshClientWrapper.ps1.
    $newDiagSshWrapper       = ${function:New-DiagnosticSshClientWrapper}
    # Connect helper that decides between a direct SSH session and a
    # jump-through-router session based on $vmRef._RouterVm. Same
    # closure-capture reason as the per-step functions above; without
    # capturing it as a variable, name-based resolution from inside
    # Invoke-WithVmFileServer's module scope would not find it.
    $newSshClientWithJump    = ${function:New-VmSshClientWithJump}

    $postBlock = {
        param($server)

        $sshClient = $null
        $sshSession = $null
        try {
            # Generous Timeout because ssh.socket binds port 22 early via
            # socket activation, so the upstream 'wait for SSH' TCP probe
            # returns true before ssh.service has actually started. The
            # client connect after port 22 opens blocks while systemd
            # activates ssh.service, which is held off by patch 2's
            # After=cloud-config.service ordering until cloud-config
            # completes. Worst observed cloud-config duration so far is
            # ~7.5 minutes when apt's noble mirror is DNS-flapping; 10 min
            # matches the upstream 'wait for SSH' budget in Invoke-VmCreation
            # and gives ~30% headroom over the worst observed run.
            #
            # Connect is synchronous with no progress output. The leading
            # Write-Host below tells the operator the silence is expected,
            # so a multi-minute wait does not read like a hang.
            #
            # New-VmSshClientWithJump branches on $vmRef._RouterVm
            # (stamped by provision.ps1 step 7 onto every workload):
            # router VMs and pre-feature-53 callers get a direct
            # New-VmSshClient session; workload VMs get a session
            # tunnelled through the router so the host's lack of a
            # route into the private subnet does not block post-
            # provisioning. The session wraps both the client and
            # (when used) the tunnel; the finally below disposes
            # them together.
            Write-Host (
                "  Connecting to $vmIp (this may take several minutes " +
                "while cloud-init finishes) ..."
            )
            $sshSession = & $newSshClientWithJump `
                              -Vm      $vmRef `
                              -Timeout ([TimeSpan]::FromMinutes(10))
            $sshClient  = $sshSession.Client

            # Replace $sshClient with a duck-type-compatible wrapper that
            # tees every RunCommand to ssh.log under the per-run diag
            # folder. Every downstream consumer (cloud-init wait, files
            # copy, reconciler, env vars) sees the wrapper via this exact
            # variable, so no other call site needs to change. The wrapper
            # forwards Disconnect/Dispose so the finally block below tears
            # the real client down correctly.
            $sshClient = & $newDiagSshWrapper `
                              -RealClient    $sshClient `
                              -VmConfigPath  $vmConfigPath `
                              -VmName        $vmName `
                              -Timestamp     $vmRef._diagTimestamp

            # cloud-init may still be running its later modules (apt holding
            # the dpkg lock, runcmd not yet started). Wait once, here, so no
            # downstream step has to know about it. The polling helper
            # (Wait-CloudInitFinished.ps1) streams dots while status is
            # unchanged and injects " [<state>]" inline on a transition;
            # the elapsed/budget summary below is stamped on the same
            # line after it returns. SSH-polling output style.
            #
            # Sub-step timer wraps just the wait so the report attributes
            # cloud-init's late-module duration to its own row rather
            # than blending it with the file/reconcile/env work.
            Write-Host "  Waiting for cloud-init to finish ..." -NoNewline
            & $invokeWithSubStepTimer `
                -Parent 'Post-provisioning' `
                -Name   'cloud-init wait' `
                -Action {
                    $waitResult = & $waitCloudInitFinished `
                        -SshClient $sshClient `
                        -VmName    $vmName
                    Write-Host (" {0}s / {1}s ({2})" -f `
                        $waitResult.ElapsedSeconds,
                        $waitResult.BudgetSeconds,
                        $waitResult.Output)
                    if ($waitResult.ExitStatus -ne 0) {
                        # Fatal. cloud-init reports non-zero specifically
                        # when a runcmd, write_files, or packages step
                        # failed - the operator-facing seed contract. The
                        # 2026-06 dnsmasq-not-installed regression rode in
                        # under a previous "warn and continue" policy that
                        # let a broken VM cascade into the assertion
                        # phase. Better to fail here with a clear
                        # cloud-init-side cause than to debug a
                        # downstream symptom.
                        #
                        # Diagnostic data: the cloud-init-output.log and
                        # cloud-init.log captures from
                        # Invoke-CloudInitDiagnostics (run above) sit in
                        # <vmConfigPath>/diagnostics/<vmName>/<timestamp>/
                        # next to console.log; the message points the
                        # operator at them so they do not have to know
                        # where to look.
                        $diagHint = if ($vmConfigPath) {
                            " Check cloud-init-output.log and cloud-init.log under $vmConfigPath\diagnostics\$vmName\$($vmRef._diagTimestamp)\."
                        } else { '' }
                        throw (
                            "cloud-init on '$vmName' completed with " +
                            "ExitStatus=$($waitResult.ExitStatus) " +
                            "(status: $($waitResult.Output)). One of the " +
                            "seed's write_files / runcmd steps failed." +
                            $diagHint
                        )
                    }
                }

            # Capture cloud-init / systemd / network state immediately
            # after cloud-init reports done. Same closure-capture rationale
            # as the other per-step functions above. $vmRef._diagTimestamp
            # was set in Invoke-VmCreation so console.log + the dumps below
            # land in the same per-run folder. See
            # Invoke-CloudInitDiagnostics.ps1 for the full output list.
            & $invokeCloudInitDiagnostics `
                -SshClient     $sshClient `
                -VmConfigPath  $vmConfigPath `
                -VmName        $vmName `
                -Timestamp     $vmRef._diagTimestamp

            # Router-only: assert load-bearing services are active
            # NOW so a service that ended up inactive (the 2026-06
            # dnsmasq race is the motivator) surfaces at provision
            # time with a clear message, not later in the E2E
            # assertion phase. Workload VMs skip this - they have
            # no router-specific services. PSObject.Properties
            # guard because tests may build a VM def without kind.
            $kind = if ($vmRef.PSObject.Properties['kind']) {
                $vmRef.kind
            } else { '' }
            if ($kind -eq 'router') {
                & $assertRouterServicesActive `
                    -SshClient $sshClient `
                    -VmName    $vmName
            }

            # Manifest store init runs unconditionally near the top of
            # the per-VM loop: it costs one cheap mkdir + chown + chmod
            # and is the single place /var/lib/infra-provisioner/ gets
            # created. Doing it here (not on demand from a provider) keeps
            # the directory's lifecycle owned by the orchestrator, so any
            # provider that lands later can assume the store exists.
            & $initManifestStore -SshClient $sshClient

            # Dispatch order: files first as a stylistic choice. Steps must
            # not depend on each other's outputs - if a future install needs
            # an artefact, it acquires its own copy.
            if ($hasFiles) {
                # Per-entry routing (single vs bulk), optional-flag
                # defaults, and ordering contract all live in
                # Invoke-VmFilesDispatch.ps1; see its docstring for
                # the policy + rationale.
                & $invokeWithSubStepTimer `
                    -Parent 'Post-provisioning' `
                    -Name   'files' `
                    -Action {
                        & $invokeVmFilesDispatch `
                            -SshClient $sshClient `
                            -Server    $server `
                            -Entries   @($vmRef.files)
                    }
            }
            
            # Reconciler dispatch. Get-Providers is parameterised by the
            # VM so each provider can capture VM-scoped state (e.g. the
            # JDK provider closes over _jdkTarballPath / _jdkResolvedVersion
            # populated by Invoke-JdkAcquisition).
            #
            # OnProviderComplete attributes each provider's wall-clock
            # to its own sub-step bucket (reconcile/<providerName>) so
            # the timing report shows where reconciler time went.
            # Failed providers still contribute their partial duration;
            # the -Failed switch makes the sub-step's status sticky
            # Failed even if a later VM's iteration succeeds.
            #
            # Re-bind $addSubStepDuration into a fresh local before the
            # inner GetNewClosure(). PowerShell's GetNewClosure only
            # snapshots the IMMEDIATE local scope's variable table -
            # lexically visible captures from a parent closure (here
            # the outer post-block, which captured $addSubStepDuration
            # from Invoke-VmPostProvisioning's scope) do NOT propagate
            # into the new closure. Without this rebind, the inner
            # closure's $addSubStepDuration is $null at invocation time
            # and the callback fails with "expression after '&' produced
            # an object that was not valid", silently leaving the
            # reconcile/<provider> sub-step rows un-updated.
            $addSubStepDurationLocal = $addSubStepDuration
            $onProviderComplete = {
                param($providerName, $elapsedMs, $hadError)
                if ($hadError) {
                    & $addSubStepDurationLocal `
                        -Parent    'Post-provisioning' `
                        -Name      "reconcile/$providerName" `
                        -ElapsedMs $elapsedMs `
                        -Failed
                } else {
                    & $addSubStepDurationLocal `
                        -Parent    'Post-provisioning' `
                        -Name      "reconcile/$providerName" `
                        -ElapsedMs $elapsedMs
                }
            }.GetNewClosure()

            & $invokeReconciliation `
                -SshClient          $sshClient `
                -Server             $server `
                -Vm                 $vmRef `
                -Providers          @(& $getProviders -Vm $vmRef) `
                -OnProviderComplete $onProviderComplete

            if ($hasEnvVars) {
                # Stylistically last: env-var values may legitimately
                # reference paths the `files` step placed or the JDK
                # install root, so writing /etc/environment after both
                # keeps log-reading less surprising. The transport itself
                # does not read the target paths it writes, so this
                # ordering is convention, not correctness.
                & $invokeWithSubStepTimer `
                    -Parent 'Post-provisioning' `
                    -Name   'envVars' `
                    -Action {
                        & $setEnvironmentVariables -SshClient $sshClient -Vm $vmRef
                    }
            }
        }
        finally {
            # $sshSession owns both the client AND (for workload VMs)
            # the underlying jump tunnel. Its Dispose tears them down
            # in the right order so the workload-side connection
            # drops before the forwarded port closes. Safe to call
            # when the session was never opened ($sshSession is $null).
            if ($null -ne $sshSession) {
                try { $sshSession.Dispose() } catch {}
            }
        }
    }.GetNewClosure()

    # File-server binding decision. Get-VmSwitchHostIp (called by
    # Invoke-WithVmFileServer's -VmIpAddress path) walks Get-NetIPAddress
    # for a host adapter on the SAME /24 as the supplied VM IP. That works
    # for legacy VMs sitting on a Hyper-V Internal vSwitch the host has
    # its own address on, but a feature-53 workload's IP lives on a
    # private switch the host has no route into - the lookup throws
    # "No host adapter found on the same /24" and post-provisioning
    # aborts before touching the workload.
    #
    # When _RouterVm is stamped on the VM, we instead bind the file
    # server on the host adapter that sits on the same upstream LAN as
    # the router's ext0 (the External vSwitch's underlying physical NIC).
    # The workload reaches that bind via its default route -> router
    # priv0 -> router MASQUERADE on ext0 -> host. Address discovery uses
    # the same Get-VmSwitchHostIp helper, just keyed off the router's
    # discovered upstream IP instead of the workload's unreachable one.
    $hasRouter = $Vm.PSObject.Properties['_RouterVm'] -and $Vm._RouterVm
    if ($hasRouter) {
        # Get-VmSwitchHostIp resolves a host adapter on the same /24 as
        # the supplied VM IP. Keyed off the router's discovered upstream
        # address rather than the workload's unreachable private IP -
        # the host's External vSwitch adapter shares that /24 by
        # construction, so the file server binds where the router's
        # MASQUERADE NAT can route workload traffic back.
        $hostIp = Get-VmSwitchHostIp -VmIpAddress $Vm._RouterVm.ipAddress
        Invoke-WithVmFileServer -HostIp $hostIp -ScriptBlock $postBlock
    } else {
        Invoke-WithVmFileServer -VmIpAddress $vmIp -ScriptBlock $postBlock
    }
}
