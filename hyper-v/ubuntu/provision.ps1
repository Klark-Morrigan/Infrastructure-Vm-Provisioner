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
    # Operator invocations pass `Production`; ephemeral fixtures
    # (parallel workflows, test harnesses, multi-tenant deployments)
    # pass their own label. Mandatory so a caller cannot silently fall
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
. "$PSScriptRoot\common\config\Read-VmProvisionerConfig.ps1"
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
# TODO(diagnostic, remove): see Invoke-CloudInitDiagnostics.ps1 +
# Invoke-SerialConsoleCapture.ps1 + New-DiagnosticSshClientWrapper.ps1
# headers. Paired diagnostic helpers.
. "$PSScriptRoot\up\post\Invoke-CloudInitDiagnostics.ps1"
. "$PSScriptRoot\up\post\Invoke-SerialConsoleCapture.ps1"
. "$PSScriptRoot\up\post\New-DiagnosticSshClientWrapper.ps1"
. "$PSScriptRoot\up\post\Invoke-VmPostProvisioning.ps1"
. "$PSScriptRoot\up\seed\New-StaticNetplanYaml.ps1"
. "$PSScriptRoot\up\seed\generate-seed-iso.ps1"
. "$PSScriptRoot\up\network\setup-network.ps1"
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
    'Virtual switch + NAT',
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
    # 4. Disk image acquisition (new VMs only)
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
    # 5. Host-side acquisitions (per VM - new AND existing)
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
    # 6. Cloud-init seed ISO generation (new VMs only)
    #    Builds meta-data, user-data, and network-config; writes the ISO.
    #    Sets $vm._seedIsoPath on each object for use in the VM-creation step.
    #    Skipped for existing VMs - cloud-init already ran on their first boot.
    # -----------------------------------------------------------------------

    Invoke-WithPhaseTimer -Name 'Cloud-init seed ISO' -Action {
        foreach ($vm in $newVms) {
            Invoke-SeedIsoGeneration -Vm $vm
        }
    }

    # -----------------------------------------------------------------------
    # 7. Virtual switch and NAT setup
    #    Switch and NAT names come from the config (default: VmLAN / VmLAN-NAT).
    #    Idempotent - safe to re-run. Always runs so a rebuilt host gets the
    #    network re-applied around already-existing VMs.
    # -----------------------------------------------------------------------

    $switchName = $vmsToProcess[0].switchName
    $natName    = $vmsToProcess[0].natName

    Invoke-WithPhaseTimer -Name 'Virtual switch + NAT' -Action {
        Invoke-NetworkSetup -VmsToProvision $vmsToProcess `
                            -SwitchName     $switchName `
                            -NatName        $natName
    }

    # -----------------------------------------------------------------------
    # 8. VM creation (new VMs only)
    #    Creates, configures, boots each VM, and waits for SSH readiness.
    #    Skipped for existing VMs.
    # -----------------------------------------------------------------------

    Invoke-WithPhaseTimer -Name 'VM creation' -Action {
        foreach ($vm in $newVms) {
            Invoke-VmCreation -Vm $vm -SwitchName $switchName
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
