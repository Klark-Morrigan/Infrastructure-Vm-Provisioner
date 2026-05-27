<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    Get-DotnetSdkProvider, which composes the four provider operations
    into a single IToolchainProvider object.
#>

# ---------------------------------------------------------------------------
# Uninstall-DotnetSdkVersion
#   Mirror of Install-DotnetSdkVersion on the removal side. The manifest is
#   the truth source for what to undo: it carries the install dir(s), the
#   /usr/local/bin/dotnet symlink, and the /etc/profile.d/dotnet.sh name.
#   Reading it back lets the uninstall path tear down precisely what the
#   install put down, without filesystem heuristics that might miss (or
#   worse, claim) unrelated paths.
#
#   Side-effect ordering is load-bearing for crash recovery, just like the
#   install side - but inverted:
#
#       1. Stop processes holding the install dir(s). A running `dotnet`
#          (e.g. an `dotnet test` left behind by a previous CI job) would
#          otherwise keep files open under /opt/dotnet-<version> and the
#          rm step would fail with "device or resource busy".
#       2. Remove /usr/local/bin/dotnet (and any other recorded symlinks).
#          Cheap and safe; doing this before the dir removal keeps the
#          broken-symlink window minimal even if rm later fails.
#       3. Remove /etc/profile.d/dotnet.sh. New login shells stop wiring
#          DOTNET_ROOT and PATH before the install dir disappears.
#       4. Remove the install dir(s). Heavy step that may legitimately
#          fail (a stuck process, a read-only mount); propagating that
#          failure keeps the manifest in place for the next reconciler
#          run.
#       5. Remove the manifest LAST. The manifest is the recovery anchor:
#          as long as it exists, the next run can replay this entire
#          uninstall. Removing it before the dir would orphan whatever
#          rm left behind.
#
#   A StillAlive from Stop-VmProcessesUsingPath (processes that survived
#   SIGTERM + grace + SIGKILL + reap) is logged and swallowed at this
#   layer. The orchestrator's transactional boundary is per-provider
#   (Invoke-ToolchainReconciliation), not per-path: aborting here would
#   leave the symlinks and profile.d script behind for no functional
#   gain. The subsequent Remove-VmDirectory will fail loudly if the stuck
#   process actually prevents removal, and that failure aborts the
#   uninstall before the manifest is removed - so the next run replays
#   cleanly.
# ---------------------------------------------------------------------------

function Uninstall-DotnetSdkVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [object] $Installed
    )

    $manifestPath = $Installed.ManifestPath

    Write-Host "  [dotnet] uninstalling $($Installed.Version) (manifest: $manifestPath)"

    # Step 0 - read the manifest. Read-VmManifest throws on a missing or
    # malformed file, which is the right behaviour here: an Installed
    # record was produced FROM a manifest by Get-DotnetSdkInstalledVersions,
    # so its absence between then and now means concurrent mutation -
    # surface it rather than guess at what to clean up.
    $manifest = Read-VmManifest -SshClient $SshClient -Path $manifestPath

    $ownedPaths          = ConvertTo-Array $manifest.ownedPaths
    $ownedSymlinks       = ConvertTo-Array $manifest.ownedSymlinks
    $ownedProfileScripts = ConvertTo-Array $manifest.ownedProfileScripts

    # Step 1 - drain processes. 30s grace matches the JDK provider; the
    # longest-running dotnet processes we expect on a CI VM (an `dotnet
    # test` runner, a `dotnet build` finishing a large solution) sit
    # comfortably under that.
    foreach ($installDir in $ownedPaths) {
        try {
            Stop-VmProcessesUsingPath `
                -SshClient    $SshClient `
                -Path         $installDir `
                -GraceSeconds 30 | Out-Null
        } catch {
            # Survivors are logged but do not abort the uninstall here;
            # see the function header for why. Remove-VmDirectory below
            # is the real authority on whether the directory can be
            # freed - if it cannot, that step throws and the manifest
            # is kept for the next replay.
            Write-Warning (
                "  [dotnet] Stop-VmProcessesUsingPath warning for " +
                "'$installDir': $($_.Exception.Message)"
            )
        }
    }

    # Step 2 - symlinks. Each link was recorded explicitly by the install
    # step (no globbing) so the uninstall removes only what this install
    # created, even if a later toolchain happens to share a binary name
    # under /usr/local/bin.
    foreach ($link in $ownedSymlinks) {
        Remove-VmSymlink -SshClient $SshClient -Path $link.path
    }

    # Step 3 - profile.d. Login shells stop wiring DOTNET_ROOT/PATH for
    # this SDK before the install dir is removed in step 4, which avoids
    # the briefly-broken-DOTNET_ROOT window an interleaved order would
    # create for any shell that logs in mid-uninstall.
    foreach ($scriptName in $ownedProfileScripts) {
        Remove-VmProfileDScript -SshClient $SshClient -Name $scriptName
    }

    # Step 3.5 - /etc/dotnet/install_location. Symmetric to the install
    # path's step 4: the file is the apphost's runtime-discovery hint for
    # non-login shells and must go away when the SDK does, otherwise
    # tool shims keep pointing at a now-deleted install dir. The path
    # is fixed (one global SDK install per VM); only the file is
    # removed, not the parent /etc/dotnet/ dir (other tooling may
    # share that directory). rm -f tolerates the file already being
    # absent so a partial-uninstall replay does not throw here.
    $installLocationCleanup = "sudo rm -f /etc/dotnet/install_location"
    $cleanupResult = Invoke-SshClientCommand `
                        -SshClient $SshClient `
                        -Command   $installLocationCleanup
    if ($cleanupResult.ExitStatus -ne 0) {
        throw (
            "Uninstall-DotnetSdkVersion: removing /etc/dotnet/install_location " +
            "failed (exit $($cleanupResult.ExitStatus)). " +
            "stdout: $($cleanupResult.Output)  " +
            "stderr: $($cleanupResult.Error)"
        )
    }

    # Step 4 - install dir(s). Heavy step that may legitimately fail
    # (a stuck process, a read-only mount); propagating that failure
    # keeps the manifest in place for the next reconciler run.
    foreach ($installDir in $ownedPaths) {
        Remove-VmDirectory -SshClient $SshClient -Path $installDir
    }

    # Step 5 - manifest LAST. Until this line runs, a crash leaves the
    # manifest claiming ownership of whatever wreckage is still on the
    # VM, and the next run will replay the same teardown.
    Remove-VmManifest -SshClient $SshClient -Path $manifestPath

    Write-Host "  [dotnet] [OK] uninstalled $($Installed.Version)." -ForegroundColor Green
}
