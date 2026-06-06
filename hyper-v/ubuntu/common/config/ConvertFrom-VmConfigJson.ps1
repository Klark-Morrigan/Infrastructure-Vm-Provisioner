<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1 and setup-secrets.ps1 after PowerShell.Common is loaded.
#>

# Sibling validators dot-sourced here so callers of ConvertFrom-VmConfigJson
# do not need to know which individual rule files exist - this file is the
# single entry point for the config schema. Assert-VmFilesField is supplied
# by Infrastructure.HyperV (already imported by Install-ModuleDependencies)
# so the shared shape checks are not duplicated across consumers.
. "$PSScriptRoot\Assert-JavaDevKitField.ps1"
. "$PSScriptRoot\Assert-DotnetSdkField.ps1"
. "$PSScriptRoot\Assert-DotnetToolsField.ps1"
. "$PSScriptRoot\Assert-RouterVmField.ps1"

# Allowed values for the 'kind' field. 'workload' is the default and
# carries the historical schema; 'router' selects the dual-NIC NAT/DNS
# gateway path added in feature 53.
$script:AllowedVmKinds = @('workload', 'router')

# ---------------------------------------------------------------------------
# ConvertFrom-VmConfigJson
#   Parses a VM provisioner JSON string and validates its structure.
#   Throws a descriptive error on any problem.
#
#   Outputs each validated VM definition object to the pipeline. Callers
#   must use ConvertTo-Array to collect the result as an array:
#       $vmDefs = ConvertTo-Array (ConvertFrom-VmConfigJson -Json $json)
#
#   Centralised here so the required-field list has a single source of
#   truth - update it once when the config schema changes.
# ---------------------------------------------------------------------------

function ConvertFrom-VmConfigJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Json
    )

    try {
        $parsed = $Json | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Invalid JSON: $_"
    }

    $vmDefs = ConvertTo-Array $parsed

    if ($vmDefs.Count -eq 0) {
        throw "Config must be a non-empty JSON array of VM definitions."
    }

    # Every VM definition must supply all of these fields. This list is the
    # authoritative schema - setup-secrets.ps1 and provision.ps1 both rely
    # on it via dot-source.
    $requiredFields = @(
        'vmName', 'cpuCount', 'ramGB', 'diskGB', 'ubuntuVersion',
        'username', 'password',
        'ipAddress', 'subnetMask', 'gateway', 'dns',
        'vmConfigPath', 'vhdPath'
    )

    foreach ($vm in $vmDefs) {
        # Assert-RequiredProperties is provided by PowerShell.Common.
        Assert-RequiredProperties `
            -Object      $vm `
            -Properties  $requiredFields `
            -Context     "VM '$(if ($vm.PSObject.Properties['vmName']) { $vm.vmName } else { '(unknown)' })'"`

        # 'kind' selects the provisioning path. Validated up front so
        # later validators run against a known kind. The allow-list is
        # closed - an unknown value is a typo, not a "future kind".
        $vmName = if ($vm.PSObject.Properties['vmName']) { $vm.vmName } else { '(unknown)' }
        if ($vm.PSObject.Properties['kind']) {
            if ($vm.kind -notin $script:AllowedVmKinds) {
                throw (
                    "VM '$vmName': kind '$($vm.kind)' is not recognised. " +
                    "Allowed: $($script:AllowedVmKinds -join ', ')."
                )
            }
        }
        $kind = if ($vm.PSObject.Properties['kind']) { $vm.kind } else { 'workload' }

        # Optional-field validators. Each one is a no-op when its field is
        # absent and throws with a descriptive message when present-but-malformed.
        # Assert-VmFilesField and Assert-VmEnvVarsField are shared validators
        # from Infrastructure.HyperV; arguments to Assert-VmFilesField are
        # spelled out so the provisioner opts into both entry forms (single
        # { source, target } and bulk { pattern, targetDir, ... }) at the
        # call site instead of relying on the cmdlet's defaults.
        # -AllowedSubFields governs only the single form; the bulk form's
        # allow-list is fixed inside Assert-VmFilesField by contract with
        # Copy-VmFilesByPattern. Assert-VmEnvVarsField owns every rule for
        # the envVars shape - the provisioner adds no per-entry policy.
        Assert-JavaDevKitField -Vm $vm
        Assert-DotnetSdkField -Vm $vm
        # Runs after Assert-DotnetSdkField so its cross-field check
        # ("dotnetTools requires dotnetSdk") sees an already-validated
        # dotnetSdk and only fires for genuine cross-field violations
        # rather than masking a malformed SDK declaration.
        Assert-DotnetToolsField -Vm $vm
        Assert-VmFilesField `
            -Vm                $vm `
            -AllowBulkEntries `
            -AllowedSubFields  @('source', 'target') `
            -PostEntryValidator $null
        Assert-VmEnvVarsField -Vm $vm

        # Router-specific schema rules run after the toolchain validators
        # so a router VM declaring (e.g.) javaDevKit fails the router
        # rejection rule with a clear message instead of being rejected
        # first by the javaDevKit shape check.
        if ($kind -eq 'router') {
            Assert-RouterVmField -Vm $vm
        }

        # Apply defaults for optional fields. Using Add-Member rather than
        # property assignment so the field is added when absent without
        # overwriting an explicitly supplied value.
        if (-not $vm.PSObject.Properties['kind']) {
            $vm | Add-Member -MemberType NoteProperty -Name kind -Value 'workload'
        }
        if (-not $vm.PSObject.Properties['switchName']) {
            $vm | Add-Member -MemberType NoteProperty -Name switchName -Value 'VmLAN'
        }
        if (-not $vm.PSObject.Properties['natName']) {
            $vm | Add-Member -MemberType NoteProperty -Name natName -Value 'VmLAN-NAT'
        }

        # Output each validated VM object individually to the pipeline.
        # Callers collect via @(ConvertFrom-VmConfigJson ...).
        Write-Output $vm
    }
}
