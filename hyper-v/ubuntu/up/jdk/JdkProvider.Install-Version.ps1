<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    Get-JdkProvider, which composes the four provider operations into
    a single IToolchainProvider object.
#>

# ---------------------------------------------------------------------------
# Install-JdkVersion
#   Composition step driven by the reconciler: extract the prefetched
#   tarball, write /etc/profile.d/jdk.sh, create /usr/local/bin symlinks
#   for every JDK binary, and finally write the manifest that records
#   ownership of all four artefact kinds.
#
#   Side-effect ordering is load-bearing for crash recovery: the manifest
#   is written LAST. If the install crashes after the extract but before
#   the manifest write, the next reconciler run sees no manifest, treats
#   the install dir as orphaned, and re-runs Install-JdkVersion which
#   Expand-VmTarball's atomic dir-swap re-extracts cleanly. A manifest
#   written first would instead claim ownership of paths that may not
#   exist yet, and the uninstall path would happily try to drain
#   processes from a directory the install never finished creating.
#
#   TarballPath and ResolvedVersion are passed as explicit parameters
#   rather than read off the Spec. They are populated host-side by
#   Invoke-JdkAcquisition onto $Vm._jdkTarballPath / $Vm._jdkResolvedVersion;
#   the Get-JdkProvider wrapper closes over the Vm and forwards them.
#   This keeps the Spec shape pure (parsed from JSON, no transient state)
#   and confines the VM-scoped transient state to the wrapper's closure.
#
#   Uses Infrastructure.HyperV 0.9.0 primitives end to end - no inline
#   bash here, so any future change to the on-VM mechanics (e.g. moving
#   /usr/local/bin to /usr/local/sbin) is a one-line change in the
#   primitive and not a hunt across providers.
# ---------------------------------------------------------------------------

function Install-JdkVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [object] $Server,

        [Parameter(Mandatory)]
        [object] $Spec,

        [Parameter(Mandatory)]
        [string] $TarballPath,

        [Parameter(Mandatory)]
        [string] $ResolvedVersion
    )

    $vendor     = $Spec.Vendor
    $installDir = "/opt/jdk-$vendor-$ResolvedVersion"

    Write-Host "  [JDK] $vendor $ResolvedVersion -> $installDir"

    # Step 1 - extract. StripComponents=1 discards the single
    # `jdk-<version>/` wrapper directory Temurin (and every other
    # mainstream OpenJDK distribution) ships at the top of its tarball.
    Expand-VmTarball `
        -SshClient       $SshClient `
        -Server          $Server `
        -TarballPath     $TarballPath `
        -Destination     $installDir `
        -StripComponents 1

    # Step 2 - login-shell PATH via /etc/profile.d. The single-quoted
    # PATH/JAVA_HOME on the right keeps the values literal in the
    # written .sh so the user's shell expands them at login, not host-
    # side at construction time. The trailing newline that
    # Set-VmProfileDScript appends if missing is fine: bash sources
    # profile.d snippets line-buffered.
    $jdkSh = "export JAVA_HOME=$installDir`nexport PATH=`"`$JAVA_HOME/bin:`$PATH`"`n"

    Set-VmProfileDScript `
        -SshClient $SshClient `
        -Name      'jdk' `
        -Content   $jdkSh

    # Step 3 - non-login-shell PATH via /usr/local/bin (sshd command
    # exec, systemd services, cron jobs - none of these read
    # /etc/profile.d/). Each link is recorded explicitly so the manifest
    # can drive the uninstall path without re-globing.
    $binaries = Get-JdkBinariesForSymlinking `
        -SshClient  $SshClient `
        -InstallDir $installDir

    $ownedSymlinks = foreach ($name in $binaries) {
        $linkPath   = "/usr/local/bin/$name"
        $linkTarget = "$installDir/bin/$name"

        New-VmSymlink `
            -SshClient $SshClient `
            -Path      $linkPath `
            -Target    $linkTarget

        [PSCustomObject]@{
            path   = $linkPath
            target = $linkTarget
        }
    }

    # Step 4 - manifest, written LAST. See the function header for why
    # the ordering matters. ownedPaths[0] is the install dir; the
    # Get-JdkInstalledVersions reader (plan step 7) assumes this
    # invariant when projecting the manifest into an Installed record.
    $manifest = [PSCustomObject]@{
        schemaVersion       = 1
        provider            = 'javaDevKit'
        version             = $ResolvedVersion
        ownedPaths          = @($installDir)
        ownedSymlinks       = @($ownedSymlinks)
        ownedProfileScripts = @('jdk')
        children            = @()
    }

    Write-VmManifest -SshClient $SshClient -Manifest $manifest

    Write-Host "  [JDK] [OK] installed under $installDir." -ForegroundColor Green
}
