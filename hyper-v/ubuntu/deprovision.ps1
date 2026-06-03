<#
.SYNOPSIS
    Remove one or more Hyper-V Ubuntu VMs from a JSON config stored in the
    local SecretStore vault.

.DESCRIPTION
    Reads the VmProvisionerConfig secret, validates each VM definition, stops
    and removes each VM with its associated files, then tears down the shared
    VmLAN network when no VMs remain on it.

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
    - If a VM in the config is not found in Hyper-V, its Hyper-V teardown is
      skipped and only file cleanup is attempted. Re-running after a partial
      failure retries the outstanding file deletions.
    - If the shared network objects (NAT rule, host vNIC IP, switch) are
      already absent, each is silently skipped.
    - If VMs outside the config are still attached to VmLAN, the network
      teardown is skipped to avoid cutting their connectivity.

    SECURITY
    - No secrets are passed as command-line arguments or written to disk.
      All sensitive values are read at runtime from the encrypted vault.
#>

[CmdletBinding()]
param(
    # Required. See provision.ps1 for the suffix contract.
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SecretSuffix
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\common\config\ConvertFrom-VmConfigJson.ps1"
. "$PSScriptRoot\common\config\Get-SanitizedVmDisplay.ps1"
. "$PSScriptRoot\common\config\Read-VmProvisionerConfig.ps1"
. "$PSScriptRoot\down\config\Assert-GatewayConsistency.ps1"
. "$PSScriptRoot\down\vm\remove-vm.ps1"
. "$PSScriptRoot\down\network\teardown-network.ps1"

# ---------------------------------------------------------------------------
# 1. Load + parse + validate the VmProvisionerConfig secret in one call.
#    Helper owns the SecretManagement bootstrap, vault read, and schema
#    validation - keeping this script focused on the deprovisioning pipeline.
# ---------------------------------------------------------------------------

$vmDefs = Read-VmProvisionerConfig -SecretSuffix $SecretSuffix

# ---------------------------------------------------------------------------
# 2. Validate gateway consistency
#    All VMs must share the same gateway - they are all attached to the same
#    Internal switch during provisioning. The gateway is needed to call
#    Invoke-NetworkTeardown, so this check runs here rather than inside that
#    function (which does not receive the full VM list).
# ---------------------------------------------------------------------------

$gatewayIp  = Assert-GatewayConsistency -VmDefs $vmDefs
$switchName = $vmDefs[0].switchName
$natName    = $vmDefs[0].natName

# ---------------------------------------------------------------------------
# 3. Per-VM removal
#    Each VM is stopped and removed from Hyper-V, then its VHDX, seed ISO,
#    and config directory are deleted. If a VM is already absent from Hyper-V
#    (re-run after partial failure), only the file cleanup is attempted.
# ---------------------------------------------------------------------------

foreach ($vm in $vmDefs) {
    Invoke-VmRemoval -Vm $vm
}

# ---------------------------------------------------------------------------
# 4. Shared network teardown
#    Invoke-NetworkTeardown checks internally whether any VMs are still
#    attached to VmLAN before removing network objects. VMs outside the
#    config that remain on the switch will cause teardown to be skipped,
#    preserving their connectivity.
# ---------------------------------------------------------------------------

Invoke-NetworkTeardown -SwitchName $switchName `
                       -Gateway    $gatewayIp `
                       -NatName    $natName

Write-Host ""
Write-Host "Deprovisioning complete." -ForegroundColor Green
