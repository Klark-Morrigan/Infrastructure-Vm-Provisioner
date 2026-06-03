<#
.NOTES
    TODO(diagnostic, remove): one-shot timing capture for attributing the
    ~363s cloud-init wait to specific modules / systemd units. Read-only
    on the VM; outputs land host-side under <VmConfigPath>/diagnostics/
    so they survive VM teardown. Remove this file, its dot-source line in
    provision.ps1, and the call in Invoke-VmPostProvisioning.ps1 once the
    numbers have been gathered and a real optimisation picked.

    Do not run this file directly. Dot-sourced by provision.ps1.
#>

# ---------------------------------------------------------------------------
# Invoke-CloudInitDiagnostics
#   Runs cloud-init / systemd analyze commands on the VM and writes each
#   output to its own file under <VmConfigPath>/diagnostics/. Called once
#   per VM, right after cloud-init has reported done.
# ---------------------------------------------------------------------------

function Invoke-CloudInitDiagnostics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $VmConfigPath
    )

    $diagDir = Join-Path $VmConfigPath 'diagnostics'
    if (-not (Test-Path -Path $diagDir -PathType Container)) {
        New-Item -ItemType Directory -Path $diagDir -Force | Out-Null
    }

    # Ordered so the headline "blame" outputs appear first in the log.
    $diagCommands = [ordered]@{
        'cloud-init-blame.txt'       = 'cloud-init analyze blame'
        'cloud-init-show.txt'        = 'cloud-init analyze show'
        'systemd-blame.txt'          = 'systemd-analyze blame'
        'systemd-critical-chain.txt' =
            'systemd-analyze critical-chain cloud-init.service cloud-init-final.service'
    }

    foreach ($entry in $diagCommands.GetEnumerator()) {
        $outPath = Join-Path $diagDir $entry.Key
        Write-Host "  [diag] $($entry.Value) -> $outPath"
        # 2>&1 server-side so stderr (systemd-analyze "ordering cycle"
        # warnings, etc.) ends up in the same dump. sh -c keeps the
        # redirect on the remote side rather than asking SSH.NET to
        # merge streams.
        $remoteCmd = "sh -c " + "'" + ($entry.Value -replace "'", "'\''") + " 2>&1'"
        $result = Invoke-SshClientCommand -SshClient $SshClient -Command $remoteCmd
        Set-Content -Path $outPath -Value $result.Output -Encoding UTF8
    }
}
