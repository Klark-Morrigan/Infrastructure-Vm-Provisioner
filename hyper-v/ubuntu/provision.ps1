<#
.SYNOPSIS
    Provision one or more Hyper-V Ubuntu VMs from a JSON config stored in the
    local SecretStore vault.

.DESCRIPTION
    Reads the VmProvisionerConfig secret, validates each VM definition, performs
    idempotency and safety checks, then provisions each VM that passes all checks.

    Run setup-secrets.ps1 once first to populate the vault before running
    this script.

.NOTES
    REQUIREMENTS
    - Windows 11 with Hyper-V enabled.
    - Run as Administrator (Hyper-V cmdlets require elevation).
    - Microsoft.PowerShell.SecretManagement + Microsoft.PowerShell.SecretStore
      installed by setup-secrets.ps1.
    - PowerShell 7+.

    IDEMPOTENCY
    - If a Hyper-V VM with the same vmName already exists, that entry is
      skipped rather than re-created.
    - If the target ipAddress responds to a ping, that entry is aborted to
      avoid a static-IP conflict with an existing machine.

    SECURITY
    - No secrets are passed as command-line arguments or written to disk.
      All sensitive values are read at runtime from the encrypted vault.
#>

[CmdletBinding()]
param(
    # Required. The vault read targets `VmProvisionerConfig-<Suffix>`.
    # Operator invocations pass `Production`; ephemeral environments
    # (parallel workflows, multi-tenant deployments) pass their own
    # label. Mandatory so a caller cannot silently fall
    # through to a default name and collide with another lifecycle's
    # data.
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SecretSuffix
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\common\config\ConvertFrom-VmConfigJson.ps1"
. "$PSScriptRoot\common\config\Get-SanitizedVmDisplay.ps1"
. "$PSScriptRoot\common\config\Group-VmsByEnvironment.ps1"
. "$PSScriptRoot\common\config\Read-VmProvisionerConfig.ps1"
. "$PSScriptRoot\common\diag\Get-VmDiagFolder.ps1"
. "$PSScriptRoot\common\diag\Invoke-VmRuntimeDiag.ps1"
. "$PSScriptRoot\common\network\Get-VmAdapterIPv4.ps1"
# Eight host-network helpers (ICS toggle, netsh portproxy x2,
# firewall, profile, DNS x2, WSL reachability probe) now ship
# in the Infrastructure.Network.Windows module. Install-ModuleDependencies
# imports it at agent startup; this file only consumes the
# exported functions. Test-WslRouterReachability transitively
# depends on Infrastructure.Wsl (auto-imported via RequiredModules).
. "$PSScriptRoot\common\network\preflight\checks\Test-IsCurrentSessionElevated.ps1"
. "$PSScriptRoot\common\network\preflight\Assert-PreflightFindings.ps1"
. "$PSScriptRoot\common\network\preflight\Assert-HostNetworkPreflight.ps1"
. "$PSScriptRoot\common\network\Assert-WorkloadReachableViaRouter.ps1"
. "$PSScriptRoot\common\network\Remove-LegacySingletonNat.ps1"
. "$PSScriptRoot\common\network\Resolve-ExistingRouterIp.ps1"
. "$PSScriptRoot\common\ssh\Assert-VmSshCredentialsAccepted.ps1"
. "$PSScriptRoot\common\ssh\Wait-VmSshBannerReachable.ps1"
. "$PSScriptRoot\common\ui\Format-ElapsedBudgetWithGradient.ps1"
# SSH jump-host helpers (New-VmSshTunnel, New-VmSshClientWithJump,
# Test-SshBanner) and the upstream-host-IP discovery (Get-VmSwitchHostIp)
# live in Infrastructure.HyperV >= 0.11.0 - imported by
# Install-ModuleDependencies above. No dot-source needed.
. "$PSScriptRoot\up\config\Select-VmsForProvisioning.ps1"
. "$PSScriptRoot\up\seed\iso.ps1"
. "$PSScriptRoot\up\disk\Invoke-BaseImagePatch.ps1"
. "$PSScriptRoot\up\disk\Invoke-DiskImageAcquisition.ps1"
. "$PSScriptRoot\up\jdk\Resolve-AdoptiumRelease.ps1"
. "$PSScriptRoot\up\jdk\Invoke-JdkAcquisition.ps1"
. "$PSScriptRoot\up\jdk\Get-JdkBinariesForSymlinking.ps1"
. "$PSScriptRoot\up\jdk\JdkProvider.Get-DesiredVersions.ps1"
. "$PSScriptRoot\up\jdk\JdkProvider.Get-InstalledVersions.ps1"
. "$PSScriptRoot\up\jdk\JdkProvider.Install-Version.ps1"
. "$PSScriptRoot\up\jdk\JdkProvider.Uninstall-Version.ps1"
. "$PSScriptRoot\up\jdk\Get-JdkProvider.ps1"
. "$PSScriptRoot\up\dotnet\Resolve-DotnetSdkRelease.ps1"
. "$PSScriptRoot\up\dotnet\Invoke-DotnetSdkAcquisition.ps1"
. "$PSScriptRoot\up\dotnet\Invoke-DotnetToolAcquisition.ps1"
. "$PSScriptRoot\up\dotnet\DotnetSdkProvider.Get-DesiredVersions.ps1"
. "$PSScriptRoot\up\dotnet\DotnetSdkProvider.Get-InstalledVersions.ps1"
. "$PSScriptRoot\up\dotnet\DotnetSdkProvider.Install-Version.ps1"
. "$PSScriptRoot\up\dotnet\DotnetSdkProvider.Uninstall-Version.ps1"
. "$PSScriptRoot\up\dotnet\Get-VmDotnetToolChildren.ps1"
. "$PSScriptRoot\up\dotnet\Get-DotnetSdkProvider.ps1"
. "$PSScriptRoot\up\dotnet\DotnetToolsProvider.Get-DesiredVersions.ps1"
. "$PSScriptRoot\up\dotnet\DotnetToolsProvider.Get-InstalledVersions.ps1"
. "$PSScriptRoot\up\dotnet\DotnetToolsProvider.Install-Version.ps1"
. "$PSScriptRoot\up\dotnet\DotnetToolsProvider.Uninstall-Version.ps1"
. "$PSScriptRoot\up\dotnet\Get-DotnetToolsProvider.ps1"
. "$PSScriptRoot\up\acquire\Invoke-VmAcquisitions.ps1"
. "$PSScriptRoot\up\reconciler\Provider-Contract.ps1"
. "$PSScriptRoot\up\reconciler\Initialize-VmManifestStore.ps1"
. "$PSScriptRoot\up\reconciler\Read-VmManifest.ps1"
. "$PSScriptRoot\up\reconciler\Write-VmManifest.ps1"
. "$PSScriptRoot\up\reconciler\Remove-VmManifest.ps1"
. "$PSScriptRoot\up\reconciler\Get-VmManifestsByProvider.ps1"
. "$PSScriptRoot\up\reconciler\Get-ProvisioningPlan.ps1"
. "$PSScriptRoot\up\reconciler\Invoke-ToolchainReconciliation.ps1"
. "$PSScriptRoot\up\reconciler\Get-Providers.ps1"
. "$PSScriptRoot\up\post\Set-EnvironmentVariables.ps1"
# Per-VM diagnostic helpers. See each file's NOTES block for the
# specific data it captures and where outputs land. All three write
# under <vmConfigPath>\diagnostics\<vmName>\<timestamp>\ so a single
# provisioning run produces one self-contained folder.
. "$PSScriptRoot\up\post\Assert-RouterReady.ps1"
. "$PSScriptRoot\up\post\Invoke-CloudInitDiagnostics.ps1"
. "$PSScriptRoot\up\post\Invoke-SerialConsoleCapture.ps1"
. "$PSScriptRoot\up\post\New-DiagnosticSshClientWrapper.ps1"
. "$PSScriptRoot\up\post\Wait-CloudInitFinished.ps1"
. "$PSScriptRoot\up\post\Invoke-VmFilesDispatch.ps1"
. "$PSScriptRoot\up\post\Invoke-VmPostProvisioning.ps1"
. "$PSScriptRoot\up\seed\New-StaticNetplanYaml.ps1"
. "$PSScriptRoot\up\seed\Get-RouterNicStaticMac.ps1"
# Shared cloud-init helpers - the workload and router seed generators
# both call these so the meta-data / users / write_files / disable-flag
# / literal-block-indent / seed-ISO-write paths have one owner.
. "$PSScriptRoot\up\seed\Initialize-SeedConfigDirectory.ps1"
. "$PSScriptRoot\up\seed\New-CloudInitMetaData.ps1"
. "$PSScriptRoot\up\seed\New-CloudInitUserBlock.ps1"
. "$PSScriptRoot\up\seed\New-CloudInitDisableNetworkConfigEntry.ps1"
. "$PSScriptRoot\up\seed\Format-CloudInitLiteralBlock.ps1"
. "$PSScriptRoot\up\seed\Write-VmSeedIso.ps1"
. "$PSScriptRoot\up\seed\generate-seed-iso.ps1"
. "$PSScriptRoot\up\seed\Invoke-RouterSeedIsoGeneration.ps1"
. "$PSScriptRoot\up\network\Initialize-ExternalSwitch.ps1"
. "$PSScriptRoot\up\network\Initialize-PrivateSwitch.ps1"
. "$PSScriptRoot\up\network\setup-network.ps1"
. "$PSScriptRoot\up\vm\Remove-VmSeedIso.ps1"
. "$PSScriptRoot\up\vm\create-vm.ps1"
. "$PSScriptRoot\up\timing\Initialize-PhaseTimings.ps1"
. "$PSScriptRoot\up\timing\Invoke-WithPhaseTimer.ps1"
. "$PSScriptRoot\up\timing\Add-SubStepDuration.ps1"
. "$PSScriptRoot\up\timing\Invoke-WithSubStepTimer.ps1"
. "$PSScriptRoot\up\timing\Write-PhaseTimingReport.ps1"

# ---------------------------------------------------------------------------
# 1. Install / import every required module via the centralised helper.
#    Dot-source so the imports land in this script's scope.
# ---------------------------------------------------------------------------

. "$PSScriptRoot\Install-ModuleDependencies.ps1"

# ---------------------------------------------------------------------------
# 2. Load + parse + validate the VmProvisionerConfig secret in one call.
#    Helper owns the SecretManagement bootstrap, vault read, and schema
#    validation - keeping this script focused on the provisioning pipeline.
# ---------------------------------------------------------------------------

$vmDefs = Read-VmProvisionerConfig -SecretSuffix $SecretSuffix

# ---------------------------------------------------------------------------
# 3. Idempotency and safety checks
#    Filters $vmDefs down to VMs that are safe to provision:
#      a) no existing Hyper-V VM with the same vmName
#      b) no machine already responding to the target ipAddress
# ---------------------------------------------------------------------------

$vmsToProcess = ConvertTo-Array (Select-VmsForProvisioning -VmDefs $vmDefs)

Write-Host ""

if ($vmsToProcess.Count -eq 0) {
    Write-Host "No VMs to process - all entries were skipped." `
        -ForegroundColor Yellow
    exit 0
}

# Split by classification. 'new' VMs go through the full destructive
# pipeline (disk acquisition, seed-ISO generation, VM creation); 'existing'
# VMs are reconciled with the idempotent additive steps only (host-side
# acquisitions + post-provisioning). Network setup is always run because
# it is idempotent and may need to be applied if the host environment was
# rebuilt around already-existing VMs.
$newVms      = ConvertTo-Array ($vmsToProcess | Where-Object { $_._state -eq 'new' })
$existingVms = ConvertTo-Array ($vmsToProcess | Where-Object { $_._state -eq 'existing' })

Write-Host ("Queued: $($newVms.Count) new VM(s), " +
            "$($existingVms.Count) existing VM(s) for reconcile.") `
    -ForegroundColor Cyan
# ---------------------------------------------------------------------------
# Phase-timing setup
#   Declare every top-level phase in dispatch order so the report can
#   list each (including any that never ran because an earlier phase
#   failed). Steps 4-9 below run inside Invoke-WithPhaseTimer wrappers
#   that record wall-clock time per phase; Write-PhaseTimingReport in
#   the outer try/finally emits the summary on success OR failure.
# ---------------------------------------------------------------------------

# Derive the reconcile/<provider> sub-step names from the registered
# provider set so Get-Providers stays the single source of truth for
# which providers exist. The synthetic placeholder is enough to build
# the provider objects (their Names are literals in their factories);
# the closure captures it but never dereferences at this stage.
$placeholderVm = [PSCustomObject]@{ vmName = '<phase-init>' }
$reconcileSubSteps = @(
    @(Get-Providers -Vm $placeholderVm) | ForEach-Object { "reconcile/$($_.Name)" }
)

Initialize-PhaseTimings -Phases @(
    # Hoisted to the front so a misconfigured host (missing switch,
    # Public profile, broken ICS DNS proxy) fails in seconds instead
    # of after minutes of disk copy + tarball download. Owns every
    # host-deterministic operation: switch ensures, legacy-NAT
    # cleanup, preflight checks, router-IP discovery, portproxy.
    'Host network setup',
    # Hashtable items pre-declare their sub-steps so the report shows
    # them as SKIPPED on runs where the work did not apply (e.g.
    # base-image cache hit suppresses the 'download base image' row,
    # ensure-none on dotnetSdk suppresses 'dotnet SDK' acquisition).
    @{
        Name     = 'Disk image acquisition'
        SubSteps = @(
            'download base image',
            'WSL2 base-image patch',
            'per-VM disk copy+resize'
        )
    },
    @{
        Name     = 'Host-side acquisitions'
        SubSteps = @('JDK', 'dotnet SDK', 'dotnet tools')
    },
    'Cloud-init seed ISO',
    @{
        Name     = 'VM creation'
        SubSteps = @('create + start', 'wait for SSH')
    },
    @{
        Name     = 'Post-provisioning'
        SubSteps = (@('cloud-init wait', 'files') +
                    $reconcileSubSteps +
                    @('envVars'))
    }
)

try {

    # -----------------------------------------------------------------------
    # 4. Host network setup
    #    Per-env: everything host-side and deterministic that has to be
    #    in place before any VM-touching work. Hoisted to phase 4 so a
    #    misconfigured host fails in seconds instead of after disk
    #    copy + tarball downloads. Order matters:
    #      a. Legacy NetNat / vNIC cleanup (Invoke-NetworkSetup) FIRST
    #         so stale state cannot falsely fail the preflight's
    #         IP-collision check.
    #      b. External + Private switches before the preflight - the
    #         preflight's first check is "switch exists".
    #      c. Assert-HostNetworkPreflight: checks 1-7 with auto-repair
    #         ON (no VMs alive yet, ICS toggle disrupts nothing).
    #      d. Router-IP discovery (existing-state routers only - new
    #         routers get their IP at step 8's KVP discovery).
    #      e. Localhost portproxy 127.0.0.1:2222 -> <routerIp>:22 so
    #         WSL-based tools (Ansible) can reach the router. Static
    #         path runs now; the DHCP follow-up runs in step 8 once
    #         create-vm.ps1 has populated $routerVm.ipAddress.
    #      f. Workload _RouterVm stamping so step 8's wait-for-SSH
    #         and step 9's post-provisioning find the jump host.
    # -----------------------------------------------------------------------

    Invoke-WithPhaseTimer -Name 'Host network setup' -Action {
        foreach ($env in (Group-VmsByEnvironment -VmDefs $vmsToProcess)) {
            if ($env.RouterVms.Count -eq 0) { continue }
            $routerVm = $env.RouterVms[0]

            Invoke-NetworkSetup -RouterVm    $routerVm `
                                -WorkloadVms $env.WorkloadVms

            Initialize-ExternalSwitch -Name           $routerVm.externalSwitchName `
                                  -NetAdapterName $routerVm.externalAdapterName
            Initialize-PrivateSwitch -Name $routerVm.privateSwitchName

            # 'gateway' is an optional, kind-specific field: the schema
            # only populates it when externalDhcp=false (static upstream).
            # A DHCP router (the default) has no gateway, so read it the
            # guarded way - an absent value leaves DnsProbeTarget empty
            # and Assert-HostNetworkPreflight simply skips the DNS-via-ICS
            # probe. Unconditional $routerVm.gateway tripped StrictMode.
            $dnsProbeTarget = if ($routerVm.PSObject.Properties['gateway']) {
                $routerVm.gateway
            } else { $null }

            Assert-HostNetworkPreflight `
                -SwitchName      $routerVm.externalSwitchName `
                -WanAdapterName  $routerVm.externalAdapterName `
                -DnsProbeTarget  $dnsProbeTarget

            Resolve-ExistingRouterIp -RouterVm $routerVm

            if ($routerVm.PSObject.Properties['ipAddress'] -and
                $routerVm.ipAddress) {
                Set-RouterSshPortProxy -ConnectAddress $routerVm.ipAddress
            }
            # Firewall companion: without an inbound allow rule on
            # the WSL vEthernet, the portproxy listens but Windows
            # silently drops WSL's packets, surfacing later as the
            # "Connection timed out during banner exchange" Ansible
            # UNREACHABLE error.
            Set-RouterSshPortProxyFirewall

            foreach ($workload in $env.WorkloadVms) {
                Add-Member -InputObject $workload `
                           -MemberType NoteProperty `
                           -Name '_RouterVm' `
                           -Value $routerVm `
                           -Force
            }
        }
    }

    # -----------------------------------------------------------------------
    # 5. Disk image acquisition (new VMs only)
    #    Downloads, converts, patches, and copies the per-VM VHDX.
    #    Sets $vm._vhdxPath on each object for use in step 8. Skipped for
    #    existing VMs - their disks already exist and re-copying would lose
    #    data.
    #
    #    Invoke-BaseImagePatch (called internally) throws a 'Wsl2NotReady:'
    #    error if WSL2 is not yet installed or initialised. We catch it here
    #    so we can print the reboot prompt and exit cleanly rather than
    #    letting the error propagate as an unhandled exception.
    # -----------------------------------------------------------------------

    Invoke-WithPhaseTimer -Name 'Disk image acquisition' -Action {
        foreach ($vm in $newVms) {
            try {
                Invoke-DiskImageAcquisition -Vm $vm
            }
            catch {
                if ($_.Exception.Message -match '^Wsl2NotReady: ') {
                    Write-Host ($_.Exception.Message -replace '^Wsl2NotReady: ', '') `
                        -ForegroundColor Yellow
                    # Print the report before exiting so the operator
                    # still sees how far we got. exit bypasses the
                    # outer finally, so call it explicitly here.
                    Write-PhaseTimingReport
                    exit 0
                }
                throw
            }
        }
    }

    # -----------------------------------------------------------------------
    # 6. Host-side acquisitions (per VM - new AND existing)
    #    Per-VM orchestrator that dispatches each per-software acquirer whose
    #    opt-in field is set on the VM definition. Self-skips for VMs with no
    #    opt-in fields. Adding a new acquirer is one dispatch line in
    #    Invoke-VmAcquisitions, not a new block here.
    #
    #    Runs for existing VMs too: the operator may have added an opt-in
    #    field (javaDevKit, ...) after the VM was originally provisioned, and
    #    each acquirer is idempotent via its on-host lockfile so re-running
    #    against an already-cached artefact is cheap.
    # -----------------------------------------------------------------------

    Invoke-WithPhaseTimer -Name 'Host-side acquisitions' -Action {
        foreach ($vm in $vmsToProcess) {
            Invoke-VmAcquisitions -Vm $vm
        }
    }

    # -----------------------------------------------------------------------
    # 7. Cloud-init seed ISO generation (new VMs only)
    #    Builds meta-data, user-data, and network-config; writes the ISO.
    #    Sets $vm._seedIsoPath on each object for use in the VM-creation step.
    #    Skipped for existing VMs - cloud-init already ran on their first boot.
    # -----------------------------------------------------------------------

    Invoke-WithPhaseTimer -Name 'Cloud-init seed ISO' -Action {
        foreach ($vm in $newVms) {
            # Branch on kind so router VMs get the dual-NIC seed
            # (Invoke-RouterSeedIsoGeneration) and workload VMs keep
            # the single-NIC seed they have always had. Schema defaults
            # 'kind' to 'workload', so this comparison is total.
            if ($vm.kind -eq 'router') {
                Invoke-RouterSeedIsoGeneration -Vm $vm
            }
            else {
                Invoke-SeedIsoGeneration -Vm $vm
            }
        }
    }

    # -----------------------------------------------------------------------
    # 8. VM creation (new VMs only)
    #    Creates, configures, boots each VM, and waits for SSH readiness.
    #    Workload VMs get one NIC on their environment's privateSwitchName;
    #    router VMs get their externalSwitchName as the primary NIC switch
    #    and Invoke-VmCreation adds the second (private) NIC internally.
    #    Skipped for existing VMs.
    # -----------------------------------------------------------------------

    Invoke-WithPhaseTimer -Name 'VM creation' -Action {
        foreach ($vm in $newVms) {
            $primarySwitch = if ($vm.kind -eq 'router') {
                $vm.externalSwitchName
            }
            else {
                $vm.privateSwitchName
            }
            Invoke-VmCreation -Vm $vm -SwitchName $primarySwitch
        }
        # Follow-up portproxy pass for routers whose IP was unknown
        # at step 4 (DHCP) and got populated by create-vm.ps1's KVP
        # discovery just above. Static routers already had their
        # portproxy set in step 4; the call is idempotent so a static
        # router whose IP did not change is a no-op. New IP at the
        # same listen target triggers a delete+re-add inside
        # Set-RouterSshPortProxy.
        foreach ($vm in $newVms | Where-Object { $_.kind -eq 'router' }) {
            if ($vm.PSObject.Properties['ipAddress'] -and $vm.ipAddress) {
                Set-RouterSshPortProxy -ConnectAddress $vm.ipAddress
                Set-RouterSshPortProxyFirewall
            }
        }
    }

    # -----------------------------------------------------------------------
    # 9. Post-provisioning (per VM - new AND existing)
    #     Opens one host file server + SSH session per VM, waits for cloud-init
    #     to finish, then dispatches each enabled step. Each step is
    #     self-contained - no cross-step file dependencies - so order between
    #     dispatched steps is not load-bearing. Skipped silently for VMs that
    #     have no opt-in fields set.
    #
    #     Runs for existing VMs too: this is what lets an operator add a
    #     'javaDevKit' or 'files' entry to a VM definition and re-run
    #     provision.ps1 to push the change. Each step is idempotent on the VM
    #     side (release-file guard, file-overwrite semantics).
    # -----------------------------------------------------------------------

    Invoke-WithPhaseTimer -Name 'Post-provisioning' -Action {
        foreach ($vm in $vmsToProcess) {
            Invoke-VmPostProvisioning -Vm $vm
        }
    }

    Write-Host ""
    Write-Host "Provisioning complete." -ForegroundColor Green
}
finally {
    Write-PhaseTimingReport
}
