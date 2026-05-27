<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    Get-DotnetToolsProvider (step 6), which composes the four provider
    operations into a single IToolchainProvider object.
#>

# ---------------------------------------------------------------------------
# Get-DotnetToolsDesiredVersions
#   Parses the optional 'dotnetTools' field on a VM definition into the
#   typed spec shape consumed by the reconciler (see Provider-Contract.ps1):
#       [PSCustomObject]@{ Provider='dotnetTools'; Version='{id}@{version}';
#                          Id; RawVersion; NupkgPath }
#
#   Diff identity. The orchestrator's Get-ProvisioningPlan matches desired
#   vs installed by Spec.Version. Two distinct tools can legitimately share
#   the same bare NuGet version ("5.4.4"), so Spec.Version must encode the
#   per-tool identity. We use '{id}@{version}' as the composite diff key
#   and carry the raw NuGet version separately under RawVersion for the
#   install step's argument vector. Get-InstalledVersions writes the same
#   composite into its records so the diff matches on no-op runs.
#
#   NupkgPath is the host-side cached .nupkg location stamped onto $Vm by
#   Invoke-DotnetToolAcquisition (step 4). The reconciler's provider
#   forwards it to Install-Version so the VM-side install does not have
#   to re-derive the cache layout.
#
#   Return values follow the provider contract:
#       absent field     -> $null  (orchestrator skips this provider)
#       explicit null    -> @()    ("ensure none installed")
#       explicit []      -> @()    (same)
#       N entries        -> array of N Spec records (order preserved)
#
#   A non-empty entry array with a missing key in $Vm._dotnetToolNupkgPaths
#   means Invoke-DotnetToolAcquisition was skipped or failed for that
#   entry; throw loud rather than let Install-Version fail later with a
#   less-actionable error.
# ---------------------------------------------------------------------------

function Get-DotnetToolsDesiredVersions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $VmConfig
    )

    # Absent field -> "skip this provider" signal (distinguished from
    # explicit null / [] so an operator who removes the field entirely
    # is not surprised by an uninstall).
    if (-not $VmConfig.PSObject.Properties['dotnetTools']) {
        return $null
    }

    $tools = $VmConfig.dotnetTools

    # Explicit null in the JSON -> ensure-none. Comma-operator wrap so
    # the empty array survives the call-operator hop in the closure
    # wrapper Get-DotnetToolsProvider builds.
    if ($null -eq $tools) {
        return ,@()
    }

    # JSON arrays parse to object[]; @() normalises a scalar-degenerate
    # input to a uniform iterable shape.
    $entries = @($tools)
    if ($entries.Count -eq 0) {
        return ,@()
    }

    # Acquisition stamp is mandatory once we have entries. Missing here
    # means Invoke-DotnetToolAcquisition did not run for this VM, and
    # producing Specs without NupkgPath would push the failure down
    # into Install-Version's SSH path where the operator gets a far
    # less actionable error.
    $pathsProp = $VmConfig.PSObject.Properties['_dotnetToolNupkgPaths']
    if ($null -eq $pathsProp -or $null -eq $pathsProp.Value) {
        throw (
            "Get-DotnetToolsDesiredVersions: VmConfig is missing " +
            "_dotnetToolNupkgPaths. Invoke-DotnetToolAcquisition must " +
            "run for this VM before the reconciler's desired-versions query."
        )
    }
    $nupkgPaths = $pathsProp.Value

    $specs = foreach ($entry in $entries) {
        $id      = [string]$entry.id
        $version = [string]$entry.version
        $key     = "$id@$version"

        if (-not $nupkgPaths.ContainsKey($key)) {
            throw (
                "Get-DotnetToolsDesiredVersions: no cached .nupkg path for " +
                "'$key' in _dotnetToolNupkgPaths. Invoke-DotnetToolAcquisition " +
                "must have stamped every desired entry."
            )
        }

        [PSCustomObject]@{
            Provider   = 'dotnetTools'
            # Composite identity drives the orchestrator's diff (two tools
            # sharing a bare NuGet version must not collide).
            Version    = $key
            Id         = $id
            RawVersion = $version
            NupkgPath  = [string]$nupkgPaths[$key]
        }
    }

    # Comma-operator return prevents PowerShell from unwrapping a single-
    # element array on the way back out - the contract specifies "array
    # of typed spec objects" and downstream code calls .Count on it.
    return ,@($specs)
}
