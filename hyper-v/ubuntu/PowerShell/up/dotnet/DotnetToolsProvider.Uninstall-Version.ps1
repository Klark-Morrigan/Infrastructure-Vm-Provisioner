<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    Get-DotnetToolsProvider (step 6), which composes the four provider
    operations into a single IToolchainProvider object.
#>

# ---------------------------------------------------------------------------
# Uninstall-DotnetToolVersion
#   Mirror of Install-DotnetToolVersion on the removal side. The manifest
#   is the truth source: it carries the install dir (in .store/), the
#   recorded /usr/local/bin/ symlinks, the id, and the raw version - all
#   the inputs the uninstall path needs to undo what install put down.
#
#   Side-effect ordering, inverted from install:
#       1. Remove the recorded /usr/local/bin/ symlinks. Each one is
#          checked against the manifest's recorded target before removal;
#          a foreign object (regular file, symlink elsewhere, missing
#          entry) is logged and skipped (Ownership boundary, problem.md).
#       2. `dotnet tool uninstall {id} --tool-path ...`. Non-zero is
#          logged but NOT thrown if the tool is already absent - the
#          symlink and manifest cleanup are the load-bearing parts;
#          `dotnet tool uninstall` only frees the .store slot.
#       3. Remove the manifest LAST. Until this line runs, a crash
#          leaves the manifest claiming ownership of whatever is still
#          on the VM, and the next reconciler run replays the teardown.
#
#   Ownership boundary. The provider only removes:
#     - /usr/local/bin/{cmd} symlinks whose existing target points into
#       /usr/local/share/dotnet/tools/ (anything else is foreign).
#     - The tool's slot in .store/ (via `dotnet tool uninstall`, the
#       supported way to free it; we never `rm -rf` the .store dir
#       directly because the driver also rewrites .store/.snapshot/).
#     - The manifest file itself.
#   It does NOT touch the shared /usr/local/share/dotnet/tools/{cmd}
#   shim binaries created by the driver (the driver removes them as
#   part of `tool uninstall`). It does NOT touch the SDK's
#   /etc/profile.d/dotnet.sh.
# ---------------------------------------------------------------------------

$script:DotnetToolsRoot = '/usr/local/share/dotnet/tools'

function Uninstall-DotnetToolVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [object] $Installed
    )

    $manifestPath = $Installed.ManifestPath

    Write-Host "  [dotnetTools] uninstalling $($Installed.Version) (manifest: $manifestPath)"

    # Step 0 - read the manifest. Read-VmManifest throws on a missing or
    # malformed file - which is the right behaviour: an Installed record
    # was produced FROM a manifest by Get-InstalledVersions, so a
    # disappearance between then and now is concurrent mutation. Surface
    # it rather than guess what to clean up.
    $manifest = Read-VmManifest -SshClient $SshClient -Path $manifestPath

    $id            = [string]$manifest.id
    $rawVersion    = [string]$manifest.rawVersion
    $ownedSymlinks = ConvertTo-Array $manifest.ownedSymlinks
    $toolsRoot     = $script:DotnetToolsRoot

    # Step 1 - symlinks. Each link's existing target on disk must point
    # into $toolsRoot before removal. Why probe instead of trust the
    # manifest's recorded target? An operator-side rebind would not be
    # caught by trusting the manifest, and we would happily delete a
    # /usr/local/bin/{cmd} that now points at an unrelated binary.
    foreach ($link in $ownedSymlinks) {
        $linkPath = [string]$link.path
        if ([string]::IsNullOrEmpty($linkPath)) { continue }

        # Read the link's current target. -L: existence-as-symlink (not
        # the referent). readlink -f: resolve all symlink hops; we only
        # need the immediate target because /usr/local/bin/{cmd} should
        # point directly at $toolsRoot/{cmd}, but readlink -f is more
        # forgiving of intermediate links and still returns a path under
        # $toolsRoot if anything in the chain leads there.
        $probeScript = "set -euo pipefail; if [ -L '$linkPath' ]; then sudo readlink -f -- '$linkPath' || true; fi"
        $probeResult = Invoke-SshClientCommand -SshClient $SshClient -Command $probeScript

        if ($probeResult.ExitStatus -ne 0) {
            Write-Warning (
                "  [dotnetTools] probe failed for symlink '$linkPath' " +
                "(exit $($probeResult.ExitStatus)); skipping. " +
                "stderr: $($probeResult.Error)"
            )
            continue
        }

        $target = [string]$probeResult.Output
        if ($null -ne $target) { $target = $target.Trim() }

        if ([string]::IsNullOrEmpty($target)) {
            # Not a symlink (or missing entirely). Either way, do nothing -
            # we never remove an entry we did not create.
            Write-Host "  [dotnetTools] symlink '$linkPath' is absent or not a symlink; skipping."
            continue
        }

        if (-not ($target.StartsWith($toolsRoot + '/') -or $target -eq $toolsRoot)) {
            Write-Warning (
                "  [dotnetTools] symlink '$linkPath' points at '$target' " +
                "(outside '$toolsRoot'); leaving in place. The provider " +
                "only removes links it owns."
            )
            continue
        }

        Remove-VmSymlink -SshClient $SshClient -Path $linkPath
    }

    # Step 2 - `dotnet tool uninstall`. Logs and continues on non-zero
    # so a stale install (manifest exists, .store/ slot already gone)
    # does not block the manifest removal. The driver returns non-zero
    # with a "not installed" message in that case; we cannot reliably
    # discriminate the message text across driver versions, so the
    # blanket log-and-continue is the safer posture for this step.
    if (-not [string]::IsNullOrEmpty($id) -and -not [string]::IsNullOrEmpty($rawVersion)) {
        $uninstallScript = "sudo dotnet tool uninstall '$id' --tool-path '$toolsRoot'"
        $uninstallResult = Invoke-SshClientCommand `
                                -SshClient $SshClient `
                                -Command   $uninstallScript
        if ($uninstallResult.ExitStatus -ne 0) {
            Write-Warning (
                "  [dotnetTools] 'dotnet tool uninstall $id' returned exit " +
                "$($uninstallResult.ExitStatus); continuing with manifest " +
                "removal. stderr: $($uninstallResult.Error)"
            )
        }
    }

    # Step 3 - manifest LAST. The recovery anchor; until removed, the
    # next reconciler run replays the teardown of any leftover state.
    Remove-VmManifest -SshClient $SshClient -Path $manifestPath

    Write-Host "  [dotnetTools] [OK] uninstalled $($Installed.Version)." -ForegroundColor Green
}
