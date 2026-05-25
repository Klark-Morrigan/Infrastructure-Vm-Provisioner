<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    Get-JdkProvider, which composes the four provider operations into
    a single IToolchainProvider object.
#>

# ---------------------------------------------------------------------------
# Uninstall-JdkVersion
#   Mirror of Install-JdkVersion on the removal side. The manifest is the
#   truth source for what to undo: it carries the install dir(s), every
#   /usr/local/bin symlink the install created, and the /etc/profile.d
#   script name. Reading it back lets the uninstall path teardown
#   precisely what the install put down, without filesystem heuristics
#   that might miss (or worse, claim) unrelated paths.
#
#   Side-effect ordering is load-bearing for crash recovery, just like
#   the install side - but inverted:
#
#       1. Stop processes that hold the install dir(s) open. A running
#          `java` would otherwise keep the directory busy on rm and the
#          bind-mount-style invariants of `/opt` would force a re-run.
#       2. Remove /usr/local/bin symlinks. Cheap and safe; doing this
#          before the dir removal means the broken-symlink window is
#          minimal even if rm later fails.
#       3. Remove /etc/profile.d/jdk.sh. New login shells stop wiring
#          JAVA_HOME and PATH before the install dir disappears.
#       4. Remove the install dir(s). This is the heavyweight step; if
#          it fails (disk error, permission), the manifest is still
#          present so the next reconciler run sees the half-removed JDK
#          and retries.
#       5. Remove the manifest LAST. The manifest is the recovery
#          anchor: as long as it exists, the next run can replay this
#          entire uninstall. Removing it before the dir would orphan
#          whatever rm left behind.
#
#   A StillAlive from Stop-VmProcessesUsingPath (processes that survived
#   SIGTERM + grace + SIGKILL + reap) is logged and swallowed at this
#   layer. The orchestrator's transactional boundary is per-provider
#   (Invoke-ToolchainReconciliation), not per-path: aborting here would
#   leave the symlinks and profile.d script behind for no functional
#   gain. The subsequent Remove-VmDirectory will fail loudly if the
#   stuck process actually prevents removal, and that failure aborts
#   the uninstall before the manifest is removed - so the next run
#   replays cleanly.
# ---------------------------------------------------------------------------

function Uninstall-JdkVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [object] $Installed
    )

    $manifestPath = $Installed.ManifestPath

    Write-Host "  [JDK] uninstalling $($Installed.Version) (manifest: $manifestPath)"

    # Step 0 - read the manifest. Read-VmManifest throws on a missing or
    # malformed file, which is the right behaviour here: an Installed
    # record was produced FROM a manifest by Get-JdkInstalledVersions,
    # so its absence between then and now means concurrent mutation -
    # surface it rather than guess at what to clean up.
    $manifest = Read-VmManifest -SshClient $SshClient -Path $manifestPath

    $ownedPaths          = ConvertTo-Array $manifest.ownedPaths
    $ownedSymlinks       = ConvertTo-Array $manifest.ownedSymlinks
    $ownedProfileScripts = ConvertTo-Array $manifest.ownedProfileScripts

    # Step 1 - drain processes. 30s grace mirrors the longest-running
    # JDK side effects we expect on a CI VM (a stuck javac compile, a
    # JVM shutdown hook waiting on a network flush); shorter would
    # falsely promote routine slow exits to SIGKILL escalations.
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
                "  [JDK] Stop-VmProcessesUsingPath warning for " +
                "'$installDir': $($_.Exception.Message)"
            )
        }
    }

    # Step 2 - symlinks. Each link was recorded explicitly by the
    # install step (no globbing) so the uninstall removes only what
    # this install created, even if a later toolchain happens to share
    # a binary name under /usr/local/bin.
    foreach ($link in $ownedSymlinks) {
        Remove-VmSymlink -SshClient $SshClient -Path $link.path
    }

    # Step 3 - profile.d. Login shells stop wiring JAVA_HOME/PATH for
    # this JDK before the install dir is removed in step 4, which
    # avoids the briefly-broken-JAVA_HOME window an interleaved order
    # would create for any shell that logs in mid-uninstall.
    foreach ($scriptName in $ownedProfileScripts) {
        Remove-VmProfileDScript -SshClient $SshClient -Name $scriptName
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

    Write-Host "  [JDK] [OK] uninstalled $($Installed.Version)." -ForegroundColor Green
}
