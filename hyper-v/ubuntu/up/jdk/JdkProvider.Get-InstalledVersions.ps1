<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    Get-JdkProvider, which composes the four provider operations into
    a single IToolchainProvider object.
#>

# ---------------------------------------------------------------------------
# Get-JdkInstalledVersions
#   Reads the on-VM manifest store and projects each javaDevKit manifest
#   into the typed installed-record shape the reconciler consumes (see
#   Provider-Contract.ps1):
#       [PSCustomObject]@{ Provider; Version; InstallPath; ManifestPath }
#
#   Manifests are the truth source for "what is installed" - they are
#   written by JdkProvider.Install-Version under
#   /var/lib/infra-provisioner/manifests/javaDevKit-<version>.json and
#   carry the install dir, owned symlinks, and profile.d names so the
#   uninstall path can mirror the install side without re-deriving any
#   of that from filesystem heuristics.
#
#   InstallPath comes from ownedPaths[0]. JdkProvider.Install-Version
#   guarantees the JDK install dir is written first; the field is a
#   list (not a scalar) only because the manifest schema allows multi-
#   path ownership in general - a JDK install only ever owns one dir.
#
#   Returns @() when no manifests exist (store missing or no javaDevKit
#   entries). "Nothing installed" is a valid state for the orchestrator,
#   not an error.
#
#   A manifest missing or empty ownedPaths throws with the offending
#   manifest path in the message. This is corruption (a manifest is only
#   written after a successful install, which by definition has at
#   least one owned path); failing loud is preferable to silently
#   skipping a manifest and leaving its install dir orphaned.
# ---------------------------------------------------------------------------

function Get-JdkInstalledVersions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient
    )

    # ConvertTo-Array normalises null / scalar / array into a flat
    # array shape without the @()-in-if-expression collapse-to-$null
    # trap (see PowerShell.Common's ConvertTo-Array header).
    $manifests = ConvertTo-Array (
        Get-VmManifestsByProvider `
            -SshClient $SshClient `
            -Provider  'javaDevKit'
    )

    if ($manifests.Count -eq 0) {
        # Comma operator preserves the empty array across the function
        # boundary (PowerShell unrolls a bare @() to $null, which breaks
        # the array contract the orchestrator relies on).
        return ,@()
    }

    $records = foreach ($manifest in $manifests) {
        # _manifestPath is attached by Get-VmManifestsByProvider; it is
        # the source-file path the uninstall step uses to remove the
        # manifest after tearing down the install.
        $manifestPath = $manifest._manifestPath

        # ownedPaths is the install dir list. Required for an
        # uninstall to know what to remove; a missing or empty value
        # means the manifest is unusable.
        $hasOwnedPaths =
            $null -ne $manifest.PSObject.Properties['ownedPaths'] -and
            $null -ne $manifest.ownedPaths -and
            @($manifest.ownedPaths).Count -gt 0

        if (-not $hasOwnedPaths) {
            throw (
                "JDK manifest '$manifestPath' has no ownedPaths; cannot " +
                "determine the install dir. The manifest is corrupt - " +
                "remove it manually and re-provision."
            )
        }

        [PSCustomObject]@{
            Provider     = 'javaDevKit'
            Version      = $manifest.version
            InstallPath  = @($manifest.ownedPaths)[0]
            ManifestPath = $manifestPath
        }
    }

    # Comma operator preserves array shape when the foreach yields a
    # single element (otherwise PowerShell unrolls it back to a scalar).
    return ,@($records)
}
