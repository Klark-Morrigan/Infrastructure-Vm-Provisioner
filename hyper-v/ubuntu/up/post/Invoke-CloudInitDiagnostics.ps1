<#
.NOTES
    TODO(diagnostic, remove): one-shot capture for attributing the
    ~363s cloud-init wait to specific modules / systemd units AND for
    diagnosing post-change regressions where cloud-init never reports
    done. Read-only on the VM; outputs land host-side under
    <VmConfigPath>/diagnostics/ so they survive VM teardown. Remove
    this file, its dot-source line in provision.ps1, and the call in
    Invoke-VmPostProvisioning.ps1 once the numbers have been gathered
    and a real optimisation picked.

    Do not run this file directly. Dot-sourced by provision.ps1.

    NOTE on hung boots: this function only runs after the post-
    provisioning SSH session opens, which is gated by
    `wait for SSH` succeeding in Invoke-VmCreation. If sshd never
    binds port 22 (e.g. cloud-config.service stalls and patch 2
    from Invoke-BaseImagePatch.ps1 keeps sshd held off), the
    function never runs. For that case run these commands manually
    against the stuck VM once it eventually comes up, or via the
    Hyper-V console.
#>

# ---------------------------------------------------------------------------
# Invoke-CloudInitDiagnostics
#   Captures cloud-init / systemd timing, status, logs, and apt state
#   from the VM and writes each output to its own file under
#   <VmConfigPath>/diagnostics/. Called once per VM, right after
#   cloud-init has reported done.
#
#   Captured outputs and what they tell you:
#
#     Timing
#       cloud-init-blame.txt        - per-module wall-clock (headline)
#       cloud-init-show.txt         - full stage / event timeline
#       systemd-blame.txt           - per-unit startup time
#       systemd-critical-chain.txt  - what cloud-final.service waited on
#
#     Status (snapshot AT capture time, so reflects post-cloud-init state)
#       cloud-init-status.txt       - `cloud-init status --long` (state, errors)
#       systemctl-failed.txt        - any units that exited non-zero
#       systemctl-cloud-init.txt    - status of all four cloud-init units
#
#     Logs (tail-only to keep files small; full logs stay on the VM)
#       cloud-init.log.tail.txt     - cloud-init's own module log
#       cloud-init-output.log.tail  - stdout/stderr from cloud-init's
#                                     subprocesses (apt, runcmd, etc.)
#       journal-cloud-config.txt    - cloud-config.service journal
#                                     (sshd ordering targets this unit,
#                                     so its journal is the first place
#                                     to look when boot hangs)
#       journal-cloud-final.txt     - cloud-final.service journal
#                                     (where apt sat for 6 min in the
#                                     prior baseline run)
#
#     Apt / package state (was the dominant time sink at 362s)
#       apt-config.txt              - `apt-config dump` (mirrors, options)
#       apt-sources.txt             - rendered /etc/apt/sources.list and
#                                     /etc/apt/sources.list.d/* contents
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

    # Ordered so the headline "blame" outputs land first in the log and
    # the most expensive / largest outputs land last. Each value is run
    # under `sh -c '... 2>&1'` so stderr is merged server-side; SSH.NET
    # has no stream-merge option of its own. Single-quotes in the
    # command body are escaped via the standard '\'' dance.
    #
    # `tail` and `journalctl -n` keep individual files bounded (~tens of
    # KB) - the full logs stay on the VM. `--no-pager` is mandatory for
    # `systemctl` and `journalctl` over non-interactive SSH; without it
    # they invoke `less` and hang the SSH command indefinitely.
    $diagCommands = [ordered]@{
        # ---------- Timing ----------
        'cloud-init-blame.txt'        = 'cloud-init analyze blame'
        'cloud-init-show.txt'         = 'cloud-init analyze show'
        'systemd-blame.txt'           = 'systemd-analyze blame'
        'systemd-critical-chain.txt'  =
            'systemd-analyze critical-chain cloud-init.service cloud-init-final.service'

        # ---------- Status ----------
        'cloud-init-status.txt'       = 'cloud-init status --long'
        'systemctl-failed.txt'        = 'systemctl --failed --no-pager'
        'systemctl-cloud-init.txt'    =
            'systemctl status --no-pager cloud-init-local.service ' +
            'cloud-init.service cloud-config.service cloud-final.service'

        # ---------- Logs (tail-only) ----------
        'cloud-init.log.tail.txt'     = 'sudo tail -n 500 /var/log/cloud-init.log'
        'cloud-init-output.log.tail.txt' =
            'sudo tail -n 500 /var/log/cloud-init-output.log'
        'journal-cloud-config.txt'    =
            'sudo journalctl --no-pager -n 200 -u cloud-config.service'
        'journal-cloud-final.txt'     =
            'sudo journalctl --no-pager -n 200 -u cloud-final.service'

        # ---------- Apt / package state ----------
        'apt-config.txt'              = 'apt-config dump'
        'apt-sources.txt'             =
            'echo "=== /etc/apt/sources.list ===" && ' +
            'cat /etc/apt/sources.list 2>/dev/null; ' +
            'for f in /etc/apt/sources.list.d/*; do ' +
            'echo "=== $f ==="; cat "$f"; done'
    }

    foreach ($entry in $diagCommands.GetEnumerator()) {
        $outPath = Join-Path $diagDir $entry.Key
        Write-Host "  [diag] $($entry.Value) -> $outPath"
        $remoteCmd = "sh -c " + "'" + ($entry.Value -replace "'", "'\''") + " 2>&1'"
        $result = Invoke-SshClientCommand -SshClient $SshClient -Command $remoteCmd
        Set-Content -Path $outPath -Value $result.Output -Encoding UTF8
    }
}
