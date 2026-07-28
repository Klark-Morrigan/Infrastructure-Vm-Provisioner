<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    ConvertFrom-VmConfigJson.ps1.
#>

# ---------------------------------------------------------------------------
# Assert-PowerShellField
#   Validates the optional 'powershell' field on a VM definition - the
#   desired PowerShell (pwsh) interpreter for that box.
#
#   The field is optional - when absent the function returns silently.
#   When present, it may take one of four shapes:
#
#       powershell: { version }                     (scalar)
#       powershell: [{ version }, ...]              (list)
#       powershell: null                            (ensure-none)
#       powershell: []                              (ensure-none)
#
#   Whichever shape is used, each non-empty entry must match the schema
#   exactly:
#       version : string matching one of three granularities
#                 ('7', '7.6', '7.6.4' - see $versionPatterns).
#
#   v1 installs one PowerShell per VM, so a list with more than one entry
#   is a hard error here - the same cap the Ansible powershell role
#   asserts on the target, failed earlier and with the VM named.
#
#   Sibling of Assert-JavaDevKitField.ps1 - same four shapes, same
#   diagnostics style - so the two validators stay easy to reason about
#   together. Unlike javaDevKit there is no 'vendor' sub-field: Microsoft
#   is the only publisher of PowerShell, so a vendor knob would be dead
#   data rather than a future extension point.
#
#   Strict-by-design: unknown sub-fields throw. This catches silent typos
#   like 'versoin' that would otherwise be ignored and silently install
#   nothing - which, for a CI runner, surfaces much later as an opaque
#   'pwsh: command not found' in a job log.
# ---------------------------------------------------------------------------

function Assert-PowerShellField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Vm
    )

    # Optional field - absence is valid and means "no PowerShell on this VM".
    if (-not $Vm.PSObject.Properties['powershell']) {
        return
    }

    $ps = $Vm.powershell

    # Context fragment for every error message - the operator needs to know
    # which VM in a multi-VM config tripped the check.
    $vmName = if ($Vm.PSObject.Properties['vmName']) { $Vm.vmName } else { '(unknown)' }
    $ctx    = "VM '$vmName': powershell"

    # Explicit null - the "ensure-none" signal. Returns silently; no
    # sub-field validation applies because there are no entries to validate.
    if ($null -eq $ps) {
        return
    }

    # Normalise scalar vs list into a single iterable so the entry-level
    # validation loop below is shape-agnostic.
    if ($ps -is [System.Management.Automation.PSCustomObject]) {
        $entries = @($ps)
    }
    elseif ($ps -is [array]) {
        $entries = @($ps)
    }
    else {
        throw (
            "$ctx must be a JSON object, an array of objects, or null. " +
            "Got [$($ps.GetType().FullName)]."
        )
    }

    # Explicit empty list - same "ensure-none" semantics as null.
    if ($entries.Count -eq 0) {
        return
    }

    # v1 hard-cap. The role enforces the same cap on the target; catching it
    # at config-parse time names the offending VM, which the role cannot.
    if ($entries.Count -gt 1) {
        throw (
            "$ctx is a list of $($entries.Count) entries; v1 supports " +
            "one PowerShell per VM."
        )
    }

    foreach ($entry in $entries) {
        Assert-PowerShellEntry -Ctx $ctx -Entry $entry
    }
}

# Validates one powershell entry. Split out so the scalar and the
# (currently single) list-entry branches share one rule set.
function Assert-PowerShellEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Ctx,

        [Parameter(Mandatory)]
        [object] $Entry
    )

    if ($null -eq $Entry -or
        $Entry -isnot [System.Management.Automation.PSCustomObject]) {
        throw "$Ctx entry must be a JSON object with a 'version' sub-field."
    }

    # Strict sub-field set. Reject anything outside this list to catch typos
    # like 'versoin' before they cause a confusing downstream error.
    $allowedFields = @('version')
    foreach ($prop in $Entry.PSObject.Properties) {
        if ($prop.Name -notin $allowedFields) {
            throw "$Ctx has unknown sub-field '$($prop.Name)'. Allowed sub-fields: $($allowedFields -join ', ')."
        }
    }

    # version: required, must be a string. Numeric JSON values are rejected
    # here so the operator gets a clear error rather than a confusing regex
    # mismatch. Rationale: JSON cannot preserve '7.6' as distinct from '7.60'
    # once parsed as a number (trailing-zero loss), and '7.6.4' is not a
    # valid JSON number at all - so 'string only' is the single consistent
    # rule. Same reasoning as javaDevKit.version.
    if (-not $Entry.PSObject.Properties['version']) {
        throw "$Ctx is missing required sub-field 'version'."
    }
    if ($Entry.version -isnot [string]) {
        throw "$Ctx.version must be a string (e.g. '7' or '7.6.4'). Numeric JSON values are not accepted."
    }

    # Three supported granularities, matching Resolve-PowerShellRelease's
    # parse gate. Anchored so partial matches like '7foo' or a prerelease
    # suffix ('7.7.0-preview.3') fail: previews are excluded by the resolver
    # anyway, so accepting one here would only defer the error.
    $versionPatterns = @(
        '^\d+$',
        '^\d+\.\d+$',
        '^\d+\.\d+\.\d+$'
    )

    $matched = $false
    foreach ($pattern in $versionPatterns) {
        if ($Entry.version -match $pattern) {
            $matched = $true
            break
        }
    }
    if (-not $matched) {
        throw "$Ctx.version '$($Entry.version)' is not a recognised granularity. Use '7', '7.6' or '7.6.4'."
    }
}
