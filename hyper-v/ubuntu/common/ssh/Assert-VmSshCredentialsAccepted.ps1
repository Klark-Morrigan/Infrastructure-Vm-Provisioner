<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1.
#>

# ---------------------------------------------------------------------------
# Assert-VmSshCredentialsAccepted
#   Asserts that the configured account actually accepts the configured
#   password over SSH. Returns nothing on success; throws a provisioner-
#   domain error (naming the likely cloud-init cause) on a rejection.
#
#   Why this exists (the gap it closes):
#     Wait-VmSshBannerReachable proves only that sshd answers with an
#     "SSH-" banner - NOT that any usable login exists. A cloud-init
#     user-creation failure (e.g. a supplementary group absent from the
#     base image makes useradd abort the whole account) leaves a VM with
#     sshd serving a banner and zero working credentials. The banner gate
#     passes, the VM is declared "ready", and the breakage only surfaces
#     much later as an opaque "Permission denied (password)" the first
#     time something tries to authenticate (e.g. a workload jumping
#     through a router). This assertion converts that silent, deferred
#     failure into a loud one at provision time, with a named cause and a
#     pointer to the boot log.
#
#   Layering:
#     The generic mechanism - connect, classify the outcome as
#     accepted / rejected / transient - lives in Test-VmSshCredential
#     (Infrastructure.HyperV), beside the other SSH probes. This function
#     is the thin provisioner-domain wrapper: it owns ONLY the cloud-init
#     interpretation of a rejection and the console-log pointer, the one
#     piece that must not leak into the reusable module. A transient /
#     unreachable error is left to propagate from Test-VmSshCredential
#     unchanged so it keeps its own diagnostic surface.
# ---------------------------------------------------------------------------
function Assert-VmSshCredentialsAccepted {
    # Test-VmSshCredential takes the username/password as plaintext (SSH.NET
    # contract); this wrapper threads them through, so suppress the paired-
    # param rule (function-scoped: the suppression ID is empty).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', 'Password')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingUsernameAndPasswordParams', '',
        Justification = 'SSH.NET requires a plaintext username/password pair')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $IpAddress,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Username,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Password,

        # Used only to compose the human-facing error message.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $VmName,

        [Parameter()]
        [int] $Port = 22,

        # Connect wall-clock budget. Mirrors New-VmSshClient's default; the
        # account either exists by now (banner already gated) or it does not.
        [Parameter()]
        [TimeSpan] $Timeout = [TimeSpan]::FromSeconds(30),

        # Optional pointer to the VM's serial-console capture so the thrown
        # message can tell the operator exactly where to read the
        # cloud-init "Failed to create user" warning.
        [Parameter()]
        [string] $ConsoleLogPath
    )

    # $true accepted, $false definitively rejected; a transient/unreachable
    # error throws out of here unchanged (and is NOT re-annotated below).
    $accepted = Test-VmSshCredential -IpAddress $IpAddress `
                                     -Username  $Username `
                                     -Password  $Password `
                                     -Port      $Port `
                                     -Timeout   $Timeout
    if ($accepted) { return }

    $hint = if ($ConsoleLogPath) {
        " Read '$ConsoleLogPath' for a cloud-init 'Failed to create " +
        "user' warning."
    } else { '' }

    throw (
        "SSH on '$VmName' is reachable but rejected the configured " +
        "credentials for user '$Username'. cloud-init most likely " +
        "failed to create the account - a supplementary group missing " +
        "from the base image makes useradd abort, leaving sshd up with " +
        "no usable login.$hint"
    )
}
