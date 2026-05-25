<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    ConvertFrom-VmConfigJson.ps1.
#>

# ---------------------------------------------------------------------------
# Assert-DotnetSdkField
#   Validates the optional 'dotnetSdk' field on a VM definition.
#
#   The field is optional - when absent the function returns silently.
#   When present, it may take one of four shapes:
#
#       dotnetSdk: { channel, version }              (scalar)
#       dotnetSdk: [{ channel, version }, ...]       (list)
#       dotnetSdk: null                              (ensure-none)
#       dotnetSdk: []                                (ensure-none)
#
#   Each non-empty entry must match the schema exactly:
#       channel : string '^\d+\.\d+$'                (e.g. '10.0')
#       version : string in one of three granularities:
#                 '^\d+$', '^\d+\.\d+$', '^\d+\.\d+\.\d+$'
#
#   v1 of the reconciled .NET SDK provider supports one SDK per VM, so a
#   list with more than one entry is a hard error here (same v1 cap the
#   provider's Get-DesiredVersions enforces).
#
#   Strict-by-design: unknown sub-fields throw to catch silent typos.
#
#   Sibling of Assert-JavaDevKitField.ps1 - same shape, same diagnostics
#   style, so the two validators stay easy to reason about together.
# ---------------------------------------------------------------------------

function Assert-DotnetSdkField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Vm
    )

    # Optional field - absence is valid and means "no .NET SDK on this VM".
    if (-not $Vm.PSObject.Properties['dotnetSdk']) {
        return
    }

    $sdk = $Vm.dotnetSdk

    # Context fragment for every error message - the operator needs to know
    # which VM in a multi-VM config tripped the check.
    $vmName = if ($Vm.PSObject.Properties['vmName']) { $Vm.vmName } else { '(unknown)' }
    $ctx    = "VM '$vmName': dotnetSdk"

    # Explicit null - the reconciler's "ensure-none" signal.
    if ($null -eq $sdk) {
        return
    }

    # Normalise scalar vs list into a single iterable so the entry-level
    # validation loop below is shape-agnostic.
    if ($sdk -is [System.Management.Automation.PSCustomObject]) {
        $entries = @($sdk)
    }
    elseif ($sdk -is [array]) {
        $entries = @($sdk)
    }
    else {
        throw (
            "$ctx must be a JSON object, an array of objects, or null. " +
            "Got [$($sdk.GetType().FullName)]."
        )
    }

    # Explicit empty list - same "ensure-none" semantics as null.
    if ($entries.Count -eq 0) {
        return
    }

    # v1 hard-cap; mirrors the provider so a bypass of the provider still
    # gets a clear error at validation time.
    if ($entries.Count -gt 1) {
        throw (
            "$ctx is a list of $($entries.Count) entries; v1 supports " +
            "one .NET SDK per VM."
        )
    }

    foreach ($entry in $entries) {
        Assert-DotnetSdkEntry -Ctx $ctx -Entry $entry
    }
}

# Validates one dotnetSdk entry. Split out so the scalar and the
# (currently single) list-entry branches share one rule set.
function Assert-DotnetSdkEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Ctx,

        [Parameter(Mandatory)]
        [object] $Entry
    )

    if ($null -eq $Entry -or
        $Entry -isnot [System.Management.Automation.PSCustomObject]) {
        throw "$Ctx entry must be a JSON object with 'channel' and 'version' sub-fields."
    }

    # Strict sub-field set. Reject anything outside this list to catch
    # typos like 'versoin' before they cause a confusing downstream error.
    $allowedFields = @('channel', 'version')
    foreach ($prop in $Entry.PSObject.Properties) {
        if ($prop.Name -notin $allowedFields) {
            throw "$Ctx has unknown sub-field '$($prop.Name)'. Allowed sub-fields: $($allowedFields -join ', ')."
        }
    }

    # channel: required, string, '<major>.<minor>'. Numeric JSON values
    # are rejected here so the operator gets a clear error rather than a
    # confusing regex mismatch - JSON parses '10.0' as Int 10, dropping
    # the trailing zero that distinguishes channels.
    if (-not $Entry.PSObject.Properties['channel']) {
        throw "$Ctx is missing required sub-field 'channel'."
    }
    if ($Entry.channel -isnot [string]) {
        throw "$Ctx.channel must be a string (e.g. '10.0'). Numeric JSON values are not accepted."
    }
    if ($Entry.channel -notmatch '^\d+\.\d+$') {
        throw "$Ctx.channel '$($Entry.channel)' must match '<major>.<minor>' (e.g. '10.0')."
    }

    # version: required, must be a string. Three accepted granularities.
    if (-not $Entry.PSObject.Properties['version']) {
        throw "$Ctx is missing required sub-field 'version'."
    }
    if ($Entry.version -isnot [string]) {
        throw "$Ctx.version must be a string (e.g. '10' or '10.0.100'). Numeric JSON values are not accepted."
    }

    # Three supported granularities. Anchored so partial matches like
    # '10foo' or '10.0.100-preview' fail.
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
        throw "$Ctx.version '$($Entry.version)' is not a recognised granularity. Use '10', '10.0' or '10.0.100'."
    }
}
