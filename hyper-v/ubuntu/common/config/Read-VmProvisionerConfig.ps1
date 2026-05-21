<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1, deprovision.ps1, and start-vms.ps1 after
    Infrastructure.Common is loaded.
#>

# Sibling helper dot-sourced here so callers of Read-VmProvisionerConfig do
# not need to know which individual helpers stitch the bootstrap together -
# this file is the single entry point for the "vault -> validated VMs" path.
. "$PSScriptRoot\ConvertFrom-VmConfigJson.ps1"

# ---------------------------------------------------------------------------
# Read-VmProvisionerConfig
#   Ensures the SecretManagement provider modules are loaded, reads the
#   VmProvisionerConfig secret from the local VmProvisioner vault, then
#   parses and validates it via ConvertFrom-VmConfigJson.
#
#   Returns the validated VM-definitions array, already collected via
#   ConvertTo-Array so callers always receive an array regardless of the
#   single-VM unwrap behaviour of ConvertFrom-Json.
#
#   The vault name (VmProvisioner) and secret name (VmProvisionerConfig)
#   are constants today; the function is parameterless to avoid
#   speculative surface for callers that do not exist.
# ---------------------------------------------------------------------------

function Read-VmProvisionerConfig {
    [CmdletBinding()]
    param()

    # SecretStore vault provider modules. setup-secrets.ps1 installs them;
    # the bootstrap path here is import-only and fails fast if either is
    # missing so the operator gets pointed at the setup script.
    foreach ($mod in @(
        'Microsoft.PowerShell.SecretManagement',
        'Microsoft.PowerShell.SecretStore'
    )) {
        if (-not (Get-Module -ListAvailable -Name $mod)) {
            throw "Module '$mod' is not installed. Run setup-secrets.ps1 first."
        }
        Import-Module $mod -ErrorAction Stop
    }

    $vaultName  = 'VmProvisioner'
    $secretName = 'VmProvisionerConfig'

    Write-Host "Reading '$secretName' from vault '$vaultName' ..." -ForegroundColor Cyan

    $vault = Get-SecretVault -Name $vaultName -ErrorAction SilentlyContinue
    if ($null -eq $vault) {
        throw "Vault '$vaultName' not found. Run setup-secrets.ps1 first."
    }

    $configJson = Get-Secret -Vault $vaultName -Name $secretName `
        -AsPlainText -ErrorAction Stop

    $vmDefs = ConvertTo-Array (ConvertFrom-VmConfigJson -Json $configJson)
    Write-Host "[OK] Config validated - $($vmDefs.Count) VM definition(s) found." `
        -ForegroundColor Green

    # -NoEnumerate so a single-VM config still arrives at the caller as
    # an array. A bare 'return $vmDefs' would unwrap the one-element
    # array and force every caller to remember the @(...) idiom.
    Write-Output -NoEnumerate $vmDefs
}
