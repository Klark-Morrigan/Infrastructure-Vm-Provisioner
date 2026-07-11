<#
.SYNOPSIS
    Captures host-side + (best-effort) guest-side runtime state for a
    named VM into <VmConfigPath>/diagnostics/<vmName>/<timestamp>/runtime-diag.log.

.DESCRIPTION
    Manual entry point for the same Invoke-VmRuntimeDiag helper that
    create-vm.ps1's wait-for-SSH and router-side reachability timeout
    paths auto-fire. Use this to inspect a wedged provisioning run
    without aborting it, or to diagnose VMs that have drifted IPs /
    lost connectivity after a successful provision.

    Resolves credentials and VmConfigPath from the SecretManagement
    vault entry the provisioner already reads (default secret name
    'VmProvisionerConfig', overrideable via -SecretSuffix to match the
    provision.ps1 / deprovision.ps1 convention).

.PARAMETER VmName
    The vmName as it appears in the config (must match the Hyper-V VM
    name exactly).

.PARAMETER SecretSuffix
    Suffix appended to 'VmProvisionerConfig' to form the secret name.
    Mirrors provision.ps1 / deprovision.ps1's -SecretSuffix parameter.

.EXAMPLE
    .\scripts\Get-VmRuntimeDiag.ps1 -VmName router-e2e -SecretSuffix '-E2E'
#>

param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $VmName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SecretSuffix
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
# The PowerShell reconciler (entry scripts + common/ helpers) lives under
# the hyper-v\ubuntu\PowerShell slice; this diag tool reuses those helpers.
$ubuntu   = Join-Path $repoRoot 'hyper-v\ubuntu\PowerShell'

# Install-ModuleDependencies.ps1 is a script BODY, not a function:
# dot-sourcing it executes the install + import directly into the
# caller's scope (the docstring on the file explains why - chicken-
# and-egg with Common.PowerShell). No explicit invocation needed.
. (Join-Path $ubuntu 'Install-ModuleDependencies.ps1')

. (Join-Path $ubuntu 'common\config\Read-VmProvisionerConfig.ps1')
. (Join-Path $ubuntu 'common\config\ConvertFrom-VmConfigJson.ps1')
. (Join-Path $ubuntu 'common\config\Get-SanitizedVmDisplay.ps1')
# Pure helpers Invoke-VmRuntimeDiag depends on. Provision.ps1
# dot-sources them too; this script mirrors the order.
. (Join-Path $ubuntu 'common\diag\Get-VmDiagFolder.ps1')
. (Join-Path $ubuntu 'common\network\Get-VmAdapterIPv4.ps1')
. (Join-Path $ubuntu 'common\diag\Invoke-VmRuntimeDiag.ps1')

# Read-VmProvisionerConfig already routes the JSON through
# ConvertFrom-VmConfigJson + ConvertTo-Array, so the return is the
# validated VM-def array. No second conversion needed.
$vms = Read-VmProvisionerConfig -SecretSuffix $SecretSuffix

$vm = $vms | Where-Object vmName -eq $VmName
if (-not $vm) {
    throw (
        "VM '$VmName' not found in the provisioner config. " +
        "Available: $(($vms | Select-Object -ExpandProperty vmName) -join ', ')"
    )
}

# Workload VMs need their _RouterVm stamped for New-VmSshClientWithJump
# to dispatch through the router. provision.ps1 step 7 normally does
# this; replicate the minimum here so the diag works for workloads too.
$routerVm = $vms | Where-Object kind -eq 'router' | Select-Object -First 1
if ($vm.kind -ne 'router' -and $routerVm) {
    $vm | Add-Member -NotePropertyName _RouterVm `
                     -NotePropertyValue $routerVm -Force
}

$diagFolder = Invoke-VmRuntimeDiag -Vm           $vm `
                                   -VmConfigPath $vm.vmConfigPath

Write-Host ""
Write-Host "Runtime diag captured under:" -ForegroundColor Green
Write-Host "  $diagFolder"
