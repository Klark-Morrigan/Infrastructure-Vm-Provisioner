<#
.SYNOPSIS
    Ensures the on-VM manifest store directory exists with root:root 0755.

.DESCRIPTION
    Single-round-trip primitive that creates
    /var/lib/infra-provisioner/manifests/ on the VM if it does not
    already exist, then normalises owner and mode. Idempotent: a second
    invocation against an already-correct directory is a no-op from the
    operator's perspective (mkdir -p + chown + chmod return 0).

    This is the ONLY place this feature creates
    /var/lib/infra-provisioner/. Read/Write/Remove/Get manifest helpers
    assume the directory exists and do not try to (re)create it - the
    orchestrator (step 5) calls Initialize-VmManifestStore once at the
    top of each per-VM loop iteration.

.PARAMETER SshClient
    A live SSH client. Caller owns the lifecycle; this function does
    not connect or dispose.
#>
function Initialize-VmManifestStore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient
    )

    # Manifest store layout is defined in
    # docs/dev/implementation/42 - dotnet sdk/problem.md. The path is
    # duplicated (with this comment) in Get-VmManifestsByProvider.ps1
    # and Write-VmManifest.ps1 so each helper file is dot-source-order
    # independent; keep the three literals in sync.
    $storePath = '/var/lib/infra-provisioner/manifests'

    # && chain so a failure at any link short-circuits with that link's
    # exit status (matches the literal shape asserted by the unit test
    # and avoids needing `set -e` plumbing for three commands).
    $command = (
        "sudo mkdir -p '$storePath' && " +
        "sudo chown root:root '$storePath' && " +
        "sudo chmod 0755 '$storePath'"
    )

    $result = Invoke-SshClientCommand -SshClient $SshClient -Command $command
    if ($result.ExitStatus -ne 0) {
        throw (
            "Initialize-VmManifestStore failed (exit $($result.ExitStatus)). " +
            "stdout: $($result.Output)  stderr: $($result.Error)"
        )
    }
}
