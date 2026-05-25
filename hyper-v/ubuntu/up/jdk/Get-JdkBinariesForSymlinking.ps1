<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    JdkProvider.Install-Version.ps1, which calls into it to enumerate
    the JDK binaries before writing /usr/local/bin symlinks and the
    manifest's ownedSymlinks list.
#>

# ---------------------------------------------------------------------------
# Get-JdkBinariesForSymlinking
#   Enumerates the JDK install dir's `bin/` over SSH and returns the
#   binary basenames so the caller can wire each one into
#   /usr/local/bin via New-VmSymlink and also record them under
#   `ownedSymlinks` in the manifest.
#
#   The reconciler's uninstall path needs the explicit list of binaries
#   that were symlinked at install time - a glob at uninstall time
#   would race against anything the operator might have added or
#   removed by hand, and the manifest is meant to be the truth source
#   for what the provider owns.
#
#   The remote command runs under the SSH user (no sudo). Expand-VmTarball
#   (Infrastructure.HyperV >= 0.9.3) lands the install dir at
#   `root:root 0755` so a `ls -1` does not need elevated access; a
#   regression on that contract surfaces here as EACCES, which the
#   throw below augments with the actual mode + ownership of the
#   install dir so the next operator does not have to re-derive the
#   diagnosis from scratch.
#
#   Throws if the listing fails or returns no entries. Both indicate
#   that the tarball extract did not produce the expected layout - a
#   silent skip would lead to an empty ownedSymlinks manifest and the
#   /etc/profile.d/jdk.sh PATH wiring would be the only way to reach
#   the JDK, breaking non-login shells (sshd command exec, systemd,
#   cron).
# ---------------------------------------------------------------------------

function Get-JdkBinariesForSymlinking {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $InstallDir
    )

    # `--` so a future change to $InstallDir cannot turn an entry into
    # a flag. Single-quoted to keep the path literal across the shell.
    $command = "ls -1 -- '$InstallDir/bin'"
    $result  = Invoke-SshClientCommand -SshClient $SshClient -Command $command

    if ($result.ExitStatus -ne 0) {
        # Augment the error with the install dir's actual mode +
        # ownership. EACCES on this listing almost always traces to
        # the install dir being 0700 (mktemp default) instead of the
        # 0755 contract Expand-VmTarball is supposed to establish.
        # Naming the observed mode + owner here keeps the next
        # diagnosis a 5-second job rather than a fresh SSH probe.
        $probe = Invoke-SshClientCommand `
            -SshClient $SshClient `
            -Command   "sudo stat -c 'mode=%a owner=%U:%G' -- '$InstallDir'"
        $modeDetail = if ($probe.ExitStatus -eq 0) {
            $probe.Output.Trim()
        } else {
            "stat probe failed (exit $($probe.ExitStatus)): $($probe.Error)"
        }
        throw (
            "Get-JdkBinariesForSymlinking failed to list '$InstallDir/bin' " +
            "(exit $($result.ExitStatus)). " +
            "stdout: $($result.Output)  stderr: $($result.Error)  " +
            "install dir: $modeDetail"
        )
    }

    # `ls` separates entries with LF; the SSH transport may also emit a
    # trailing CR depending on TTY state. Trim per-line and drop empties
    # so a stray blank line does not produce a "" symlink target.
    $names = @(
        ($result.Output -split "`n") |
            ForEach-Object { $_.Trim() } |
            Where-Object   { $_ -ne '' }
    )

    if ($names.Count -eq 0) {
        throw (
            "Get-JdkBinariesForSymlinking found no entries under " +
            "'$InstallDir/bin'. The tarball extract produced no JDK " +
            "binaries; the install dir is unusable."
        )
    }

    # Comma operator preserves array shape across the function boundary
    # in the single-entry case.
    return ,@($names)
}
