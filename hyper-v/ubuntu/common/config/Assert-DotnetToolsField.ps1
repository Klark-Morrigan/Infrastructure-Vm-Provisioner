<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    ConvertFrom-VmConfigJson.ps1.
#>

# ---------------------------------------------------------------------------
# Assert-DotnetToolsField
#   Validates the optional 'dotnetTools' field on a VM definition.
#
#   The field is optional - when absent the function returns silently.
#   When present, it may take one of three shapes:
#
#       dotnetTools: [{ id, version }, ...]          (list)
#       dotnetTools: null                            (ensure-none)
#       dotnetTools: []                              (ensure-none)
#
#   Each entry must match the schema exactly:
#       id      : non-empty string matching '^[A-Za-z0-9._-]+$'
#                 (the NuGet package id grammar)
#       version : non-empty string; exact pin only - no whitespace,
#                 no 'latest', no floating ranges like '[1.0,2.0)'.
#
#   Strict-by-design: unknown sub-fields throw to catch silent typos.
#
#   Cross-field: dotnetTools entries cannot install without a .NET SDK on
#   the same VM, so a non-empty dotnetTools with absent / null / empty
#   dotnetSdk fails here. The check lives in this file (rather than in
#   Assert-DotnetSdkField) because the .NET tools field is the dependant -
#   absence of dotnetSdk on its own is a valid configuration.
#
#   Sibling of Assert-DotnetSdkField.ps1 - same shape, same diagnostics
#   style, so the two validators stay easy to reason about together.
# ---------------------------------------------------------------------------

function Assert-DotnetToolsField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Vm
    )

    # Optional field - absence is valid and means "no .NET tools on this VM".
    if (-not $Vm.PSObject.Properties['dotnetTools']) {
        return
    }

    $tools = $Vm.dotnetTools

    # Context fragment for every error message - the operator needs to know
    # which VM in a multi-VM config tripped the check.
    $vmName = if ($Vm.PSObject.Properties['vmName']) { $Vm.vmName } else { '(unknown)' }
    $ctx    = "VM '$vmName': dotnetTools"

    # Explicit null - the reconciler's "ensure-none" signal.
    if ($null -eq $tools) {
        return
    }

    # dotnetTools is strictly a list shape (unlike dotnetSdk which also
    # accepts a scalar object for the single-SDK-per-VM v1 cap). Tools
    # are inherently multi-valued, so the scalar shorthand would only
    # add ambiguity.
    if ($tools -isnot [array]) {
        throw (
            "$ctx must be a JSON array of { id, version } objects, or " +
            "null. Got [$($tools.GetType().FullName)]."
        )
    }

    $entries = @($tools)

    # Empty list is the "ensure-none" signal. Allowed regardless of whether
    # dotnetSdk is present - "no tools" is a coherent state on any VM,
    # SDK or not.
    if ($entries.Count -eq 0) {
        return
    }

    # Cross-field gate. A populated dotnetTools without an SDK on the same
    # VM cannot install or run, so fail here rather than deep in the
    # acquirer. Message names both fields so the operator knows exactly
    # what to add.
    if (-not (Test-HasDotnetSdk -Vm $Vm)) {
        throw (
            "$ctx requires dotnetSdk on the same VM (dotnetTools entries " +
            "cannot install or run without a .NET SDK). Add a dotnetSdk " +
            "object to this VM or remove the dotnetTools field."
        )
    }

    foreach ($entry in $entries) {
        Assert-DotnetToolsEntry -Ctx $ctx -Entry $entry
    }
}

# Tests whether the VM has a usable dotnetSdk declaration. Mirrors the
# "absent / null / []" ensure-none semantics enforced by
# Assert-DotnetSdkField so the cross-field check here treats the same
# three inputs as "no SDK requested".
function Test-HasDotnetSdk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Vm
    )

    if (-not $Vm.PSObject.Properties['dotnetSdk']) { return $false }
    $sdk = $Vm.dotnetSdk
    if ($null -eq $sdk)                 { return $false }
    if ($sdk -is [array] -and $sdk.Count -eq 0) { return $false }
    return $true
}

# Validates one dotnetTools entry. Split out so the validation loop
# above stays a simple foreach.
function Assert-DotnetToolsEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Ctx,

        [Parameter(Mandatory)]
        [object] $Entry
    )

    if ($null -eq $Entry -or
        $Entry -isnot [System.Management.Automation.PSCustomObject]) {
        throw "$Ctx entry must be a JSON object with 'id' and 'version' sub-fields."
    }

    # Strict sub-field set. Reject anything outside this list to catch
    # typos like 'versoin' before they cause a confusing downstream error.
    $allowedFields = @('id', 'version')
    foreach ($prop in $Entry.PSObject.Properties) {
        if ($prop.Name -notin $allowedFields) {
            throw "$Ctx entry has unknown sub-field '$($prop.Name)'. Allowed sub-fields: $($allowedFields -join ', ')."
        }
    }

    # id: required, non-empty string, NuGet id grammar. Anchored regex so
    # partial matches like 'good/bad' or 'has space' fail.
    if (-not $Entry.PSObject.Properties['id']) {
        throw "$Ctx entry is missing required sub-field 'id'."
    }
    if ($Entry.id -isnot [string]) {
        throw "$Ctx entry.id must be a string."
    }
    if ([string]::IsNullOrEmpty($Entry.id)) {
        throw "$Ctx entry.id must be a non-empty string."
    }
    if ($Entry.id -notmatch '^[A-Za-z0-9._-]+$') {
        throw "$Ctx entry.id '$($Entry.id)' is not a valid NuGet package id (allowed: A-Z, a-z, 0-9, '.', '_', '-')."
    }

    # version: required, non-empty string, exact pin only. The three
    # rejections (whitespace, 'latest', floating range) are the concrete
    # shapes problem.md calls out as out-of-scope for v1.
    if (-not $Entry.PSObject.Properties['version']) {
        throw "$Ctx entry is missing required sub-field 'version'."
    }
    if ($Entry.version -isnot [string]) {
        throw "$Ctx entry.version must be a string."
    }
    if ([string]::IsNullOrEmpty($Entry.version)) {
        throw "$Ctx entry.version must be a non-empty string."
    }
    if ($Entry.version -match '\s') {
        throw "$Ctx entry.version '$($Entry.version)' must not contain whitespace."
    }
    if ($Entry.version -eq 'latest') {
        throw "$Ctx entry.version 'latest' is not allowed; v1 requires an exact version pin."
    }
    # Floating ranges always include a bracket char. Cheap, sufficient
    # rejection for the NuGet range grammar without a full parser.
    if ($Entry.version -match '[\[\]\(\),]') {
        throw "$Ctx entry.version '$($Entry.version)' looks like a floating range; v1 requires an exact version pin."
    }
}
