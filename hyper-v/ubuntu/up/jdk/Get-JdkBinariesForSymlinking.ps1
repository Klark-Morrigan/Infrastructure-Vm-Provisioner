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
#   The legacy Install-Jdk uses an on-VM glob loop and never records
#   the resulting links anywhere. The reconciler's uninstall path
#   needs the explicit list - a glob at uninstall time would race
#   against anything the operator might have added or removed by
#   hand, and the manifest is meant to be the truth source for what
#   the provider owns.
#
#   The remote command runs under the SSH user (no sudo): /opt/jdk-*
#   is world-readable after Expand-VmTarball extracts it under
#   `root:root 0755`, and a `ls -1` does not need write access.
#
#   Throws if the listing fails or returns no entries. Both indicate
#   that the tarball extract did not produce the expected layout - a
#   silent skip would lead to an empty ownedSymlinks manifest and the
#   /etc/profile.d/jdk.sh PATH wiring would be the only way to reach
#   the JDK, breaking non-login shells (sshd command exec, systemd,
#   cron). See Install-Jdk.ps1's existing comment for the rationale.
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
        throw (
            "Get-JdkBinariesForSymlinking failed to list '$InstallDir/bin' " +
            "(exit $($result.ExitStatus)). " +
            "stdout: $($result.Output)  stderr: $($result.Error)"
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
