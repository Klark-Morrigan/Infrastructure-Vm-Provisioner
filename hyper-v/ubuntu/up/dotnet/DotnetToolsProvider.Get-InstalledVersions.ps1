<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    Get-DotnetToolsProvider (step 6), which composes the four provider
    operations into a single IToolchainProvider object.
#>

# ---------------------------------------------------------------------------
# Get-DotnetToolsInstalledVersions
#   Reads the on-VM manifest store and projects each dotnetTools manifest
#   into the typed installed-record shape the reconciler consumes (see
#   Provider-Contract.ps1):
#       [PSCustomObject]@{ Provider; Version; InstallPath; ManifestPath;
#                          Id; RawVersion; Symlinks }
#
#   Manifest is the SOLE source of truth - the operation never reads
#   `dotnet tool list`, the `.store/` directory, or `/usr/local/bin/` to
#   enumerate. The provider only owns paths it itself wrote a manifest
#   for; anything else is foreign and must not be classified as installed
#   (see problem.md "Ownership boundary").
#
#   Composite Version. The orchestrator's Get-ProvisioningPlan matches
#   desired vs installed by Spec.Version. Two distinct tools can share a
#   bare NuGet version (e.g. "5.4.4"), so this record's Version field is
#   the composite '{id}@{version}' - same key Get-DesiredVersions emits -
#   to keep the diff per-tool.
#
#   InstallPath comes from ownedPaths[0]. Install-Version records the
#   per-tool /usr/local/share/dotnet/tools/.store/{id}/{version}/ dir
#   first; the field is a list (not a scalar) only because the manifest
#   schema allows multi-path ownership in general.
#
#   Symlinks is the recorded list of /usr/local/bin/* symlinks the
#   install created, used by Uninstall-Version to know exactly which
#   entries it owns. Each item is {path, target}.
#
#   Malformed manifest (missing/empty ownedPaths, missing id, missing
#   version) is logged and skipped, NOT thrown. A poison manifest must
#   not break the reconciler's whole pass for the provider - other
#   tools may still need reconciling. The corrupt file stays on disk
#   so an operator can inspect it.
# ---------------------------------------------------------------------------

function Get-DotnetToolsInstalledVersions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient
    )

    $manifests = ConvertTo-Array (
        Get-VmManifestsByProvider `
            -SshClient $SshClient `
            -Provider  'dotnetTools'
    )

    if ($manifests.Count -eq 0) {
        return ,@()
    }

    $records = foreach ($manifest in $manifests) {
        $manifestPath = $manifest._manifestPath

        # Field-shape gate. Missing/blank id / version / ownedPaths is
        # corruption (the manifest is only written after a successful
        # install, which by definition has all three). Log and skip;
        # see header for why this is not a throw.
        $idProp        = $manifest.PSObject.Properties['id']
        $versionProp   = $manifest.PSObject.Properties['version']
        $ownedProp     = $manifest.PSObject.Properties['ownedPaths']
        $symlinksProp  = $manifest.PSObject.Properties['ownedSymlinks']

        $id      = if ($idProp)      { [string]$idProp.Value      } else { '' }
        $version = if ($versionProp) { [string]$versionProp.Value } else { '' }
        # ConvertTo-Array (not @(...)) so a single string value does not
        # collapse to a scalar that breaks the .Count check below under
        # strict mode.
        $owned   = if ($ownedProp)   { ConvertTo-Array $ownedProp.Value } else { ,@() }

        $skip = $false
        if ([string]::IsNullOrWhiteSpace($id)) {
            Write-Warning (
                "  [dotnetTools] manifest '$manifestPath' has no id field; " +
                "skipping. Inspect the file and remove or re-provision."
            )
            $skip = $true
        }
        elseif ([string]::IsNullOrWhiteSpace($version)) {
            Write-Warning (
                "  [dotnetTools] manifest '$manifestPath' has no version field; " +
                "skipping. Inspect the file and remove or re-provision."
            )
            $skip = $true
        }
        elseif ($owned.Count -eq 0) {
            Write-Warning (
                "  [dotnetTools] manifest '$manifestPath' has no ownedPaths; " +
                "skipping. Inspect the file and remove or re-provision."
            )
            $skip = $true
        }

        if (-not $skip) {
            # Symlinks list is optional in shape but Install-Version always
            # writes it. Default to @() so Uninstall-Version can iterate
            # uniformly without a null check.
            $symlinks = if ($symlinksProp -and $null -ne $symlinksProp.Value) {
                @($symlinksProp.Value)
            } else {
                @()
            }

            [PSCustomObject]@{
                Provider     = 'dotnetTools'
                # Composite identity for the orchestrator's diff.
                Version      = "$id@$version"
                Id           = $id
                RawVersion   = $version
                InstallPath  = [string]$owned[0]
                ManifestPath = $manifestPath
                Symlinks     = $symlinks
            }
        }
    }

    return ,@($records)
}
