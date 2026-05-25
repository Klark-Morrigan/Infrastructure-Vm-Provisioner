<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    Get-JdkProvider, which composes the four provider operations into
    a single IToolchainProvider object.
#>

# ---------------------------------------------------------------------------
# Get-JdkDesiredVersions
#   Parses the optional 'javaDevKit' field on a VM definition into the typed
#   spec shape consumed by the reconciler (see Provider-Contract.ps1):
#       [PSCustomObject]@{ Provider='javaDevKit'; Vendor; Version }
#
#   Two input shapes are accepted so the reconciler can serve both the
#   single-JDK scalar shape and the list shape:
#       javaDevKit: { vendor, version }              (scalar)
#       javaDevKit: [{ vendor, version }, ...]       (list)
#   The scalar is normalised to a one-element list at this layer so every
#   consumer below works against a single shape.
#
#   Return values follow the provider contract:
#       absent field    -> $null  (orchestrator skips this provider)
#       explicit null   -> @()    ("ensure none installed")
#       explicit []     -> @()    (same)
#       one entry       -> array of one Spec record
#
#   v1 of the JDK provider constrains the list to length 1. Multi-JDK
#   coexistence on one VM would require per-version JAVA_HOME / PATH
#   wiring beyond the single profile.d script the installer writes
#   today. A length-greater-than-1 input is therefore a hard error -
#   failing loud here is preferable to silently installing only the
#   first entry and leaving operators wondering why the others were
#   ignored.
# ---------------------------------------------------------------------------

function Get-JdkDesiredVersions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $VmConfig
    )

    # Absent field is the "skip this provider" signal in the contract.
    # Distinguished from explicit null / [] so an operator who removes
    # the field entirely is not surprised by an uninstall.
    if (-not $VmConfig.PSObject.Properties['javaDevKit']) {
        return $null
    }

    $jdk = $VmConfig.javaDevKit

    # Explicit null in the JSON (javaDevKit: null) -> ensure-none.
    if ($null -eq $jdk) {
        return @()
    }

    # Normalise scalar (JSON object -> PSCustomObject) vs list (JSON array
    # -> object[]) into a single iterable. Wrapping with @(...) collapses
    # the scalar case to a one-element array and leaves the list case
    # unchanged; -is [array] is the safe discriminator because
    # PSObject.Properties does not see array indices.
    if ($jdk -is [System.Management.Automation.PSCustomObject]) {
        $entries = @($jdk)
    }
    elseif ($jdk -is [array]) {
        $entries = @($jdk)
    }
    else {
        throw (
            "javaDevKit must be a JSON object or array of objects; " +
            "got [$($jdk.GetType().FullName)]."
        )
    }

    # Explicit [] in the JSON -> ensure-none. Counted post-wrap so the
    # check fires for both an empty array literal and the (degenerate)
    # case of an array that flattened to zero entries.
    if ($entries.Count -eq 0) {
        return @()
    }

    # v1 hard-cap. The message names the observed count so an operator
    # editing a list does not have to recount it by hand.
    if ($entries.Count -gt 1) {
        throw (
            "javaDevKit v1 supports one JDK per VM; got $($entries.Count) " +
            "entries."
        )
    }

    $entry = $entries[0]

    # Comma-operator return prevents PowerShell from unwrapping the
    # one-element array on the way back out - the contract specifies
    # "array of typed spec objects" and downstream code calls .Count on
    # it.
    return ,@(
        [PSCustomObject]@{
            Provider = 'javaDevKit'
            Vendor   = $entry.vendor
            Version  = $entry.version
        }
    )
}
