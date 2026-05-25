<#
.SYNOPSIS
    Removes one manifest file from the on-VM store. Idempotent.

.DESCRIPTION
    Runs `sudo rm -f -- '<Path>'` over SSH. `-f` silences
    "no such file" so the helper can be called by uninstall paths
    without first checking existence - the manifest is the recovery
    anchor for partial uninstalls, so it is removed LAST, and a
    repeated removal after a crash must be safe.

    Validation is shared with Read-VmManifest (Assert-VmManifestPath)
    so an instance accepted by one cmdlet cannot be rejected by the
    other.

.PARAMETER SshClient
    A live SSH client. Caller owns the lifecycle.

.PARAMETER Path
    Absolute POSIX path of the manifest file on the VM.
#>
function Remove-VmManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $Path
    )

    Assert-VmManifestPath -Path $Path -CmdletName 'Remove-VmManifest'

    $command = "sudo rm -f -- '$Path'"
    $result  = Invoke-SshClientCommand -SshClient $SshClient -Command $command

    if ($result.ExitStatus -ne 0) {
        throw (
            "Remove-VmManifest failed for '$Path' " +
            "(exit $($result.ExitStatus)). " +
            "stdout: $($result.Output)  stderr: $($result.Error)"
        )
    }
}
