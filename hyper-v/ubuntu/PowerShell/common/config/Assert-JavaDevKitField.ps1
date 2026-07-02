<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    ConvertFrom-VmConfigJson.ps1.
#>

# ---------------------------------------------------------------------------
# Assert-JavaDevKitField
#   Validates the optional 'javaDevKit' field on a VM definition.
#
#   The field is optional - when absent the function returns silently.
#   When present, it may take one of four shapes:
#
#       javaDevKit: { vendor, version }              (scalar)
#       javaDevKit: [{ vendor, version }, ...]       (list)
#       javaDevKit: null                             (ensure-none)
#       javaDevKit: []                               (ensure-none)
#
#   Whichever shape is used, each non-empty entry must match the schema
#   exactly:
#       vendor  : 'temurin'                          (only value)
#       version : string matching one of four
#                 granularities (see $versionPatterns).
#
#   v1 of the reconciled JDK provider supports one JDK per VM, so a list
#   with more than one entry is a hard error here (same v1 cap the
#   provider's Get-DesiredVersions enforces).
#
#   Lives in its own file so the rule set stays self-contained and
#   ConvertFrom-VmConfigJson.ps1 stays a thin orchestrator.
#
#   Strict-by-design: unknown sub-fields throw. This catches silent typos
#   like 'versoin' that would otherwise be ignored and silently install
#   the wrong (or no) JDK.
# ---------------------------------------------------------------------------

function Assert-JavaDevKitField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Vm
    )

    # Optional field - absence is valid and means "no JDK on this VM".
    if (-not $Vm.PSObject.Properties['javaDevKit']) {
        return
    }

    $jdk = $Vm.javaDevKit

    # Context fragment for every error message - the operator needs to know
    # which VM in a multi-VM config tripped the check.
    $vmName = if ($Vm.PSObject.Properties['vmName']) { $Vm.vmName } else { '(unknown)' }
    $ctx    = "VM '$vmName': javaDevKit"

    # Explicit null - the reconciler's "ensure-none" signal. Returns
    # silently; no sub-field validation applies because there are no
    # entries to validate.
    if ($null -eq $jdk) {
        return
    }

    # Normalise scalar vs list into a single iterable so the entry-level
    # validation loop below is shape-agnostic. The scalar branch carries
    # the legacy shape forward unchanged; the list branch is the new
    # feature-42 shape.
    if ($jdk -is [System.Management.Automation.PSCustomObject]) {
        $entries = @($jdk)
    }
    elseif ($jdk -is [array]) {
        $entries = @($jdk)
    }
    else {
        throw (
            "$ctx must be a JSON object, an array of objects, or null. " +
            "Got [$($jdk.GetType().FullName)]."
        )
    }

    # Explicit empty list - same "ensure-none" semantics as null.
    if ($entries.Count -eq 0) {
        return
    }

    # v1 hard-cap; mirrors Get-JdkDesiredVersions so an operator who
    # bypasses the provider (e.g. via a hand-rolled config tool) still
    # gets a clear error at validation time rather than at reconcile
    # time.
    if ($entries.Count -gt 1) {
        throw (
            "$ctx is a list of $($entries.Count) entries; v1 supports " +
            "one JDK per VM."
        )
    }

    foreach ($entry in $entries) {
        Assert-JavaDevKitEntry -Ctx $ctx -Entry $entry
    }
}

# Validates one javaDevKit entry. Split out so the scalar and the
# (currently single) list-entry branches share one rule set.
function Assert-JavaDevKitEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Ctx,

        [Parameter(Mandatory)]
        [object] $Entry
    )

    if ($null -eq $Entry -or
        $Entry -isnot [System.Management.Automation.PSCustomObject]) {
        throw "$Ctx entry must be a JSON object with 'vendor' and 'version' sub-fields."
    }

    # Strict sub-field set. Reject anything outside this list to catch
    # typos like 'versoin' before they cause a confusing downstream error.
    # 'uninstall' is explicitly diagnosed so JSON carrying it (a removed
    # sub-field) gets a pointer at the new removal shape rather than a
    # generic "unknown sub-field".
    $allowedFields = @('vendor', 'version')
    foreach ($prop in $Entry.PSObject.Properties) {
        if ($prop.Name -eq 'uninstall') {
            throw (
                "$Ctx.uninstall is no longer supported. To uninstall a " +
                "JDK, set 'javaDevKit' to null or [] (or remove the " +
                "field entirely)."
            )
        }
        if ($prop.Name -notin $allowedFields) {
            throw "$Ctx has unknown sub-field '$($prop.Name)'. Allowed sub-fields: $($allowedFields -join ', ')."
        }
    }

    # vendor: required. Adoptium Temurin is currently the only supported value.
    if (-not $Entry.PSObject.Properties['vendor']) {
        throw "$Ctx is missing required sub-field 'vendor'."
    }
    if ($Entry.vendor -ne 'temurin') {
        throw "$Ctx.vendor must be 'temurin' (got '$($Entry.vendor)'). Adoptium Temurin is currently the only supported vendor."
    }

    # version: required, must be a string. Numeric JSON values are rejected
    # here so the operator gets a clear error rather than a confusing regex
    # mismatch. Rationale: JSON has no way to preserve '21.0' as distinct
    # from '21' once parsed as a number (trailing-zero loss), and '21.0.5+11'
    # is not a valid JSON number at all - so 'string only' is the single
    # consistent rule.
    if (-not $Entry.PSObject.Properties['version']) {
        throw "$Ctx is missing required sub-field 'version'."
    }
    if ($Entry.version -isnot [string]) {
        throw "$Ctx.version must be a string (e.g. '21' or '21.0.5+11'). Numeric JSON values are not accepted."
    }

    # Four supported granularities. Anchored so partial matches like
    # '21foo' or '21.0.5+11-extra' fail.
    $versionPatterns = @(
        '^\d+$',
        '^\d+\.\d+$',
        '^\d+\.\d+\.\d+$',
        '^\d+\.\d+\.\d+\+\d+$'
    )

    $matched = $false
    foreach ($pattern in $versionPatterns) {
        if ($Entry.version -match $pattern) {
            $matched = $true
            break
        }
    }
    if (-not $matched) {
        throw "$Ctx.version '$($Entry.version)' is not a recognised granularity. Use '21', '21.0', '21.0.5' or '21.0.5+11'."
    }
}
