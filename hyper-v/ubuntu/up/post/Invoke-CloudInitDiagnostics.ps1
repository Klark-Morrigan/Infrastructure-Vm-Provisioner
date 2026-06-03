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
#       ssh-units-status.txt        - status of ssh.service + ssh.socket
#                                     (verifies patch 2's ordering took)
#       ssh-units-config.txt        - merged unit config (systemctl cat),
#                                     is-enabled state, and sockets
#                                     target.wants/ symlinks - tells us
#                                     whether ssh.socket actually runs
#                                     and whether patch 2's drop-in is
#                                     being applied
#
#     Network (root cause of most slow runs - DNS timing out makes
#     apt-get update sit on retries for several minutes per source)
#       network-interfaces.txt      - `ip addr` + `ip route` + `ip rule`
#                                     (interface IPs, routing table)
#       network-resolv.txt          - /etc/resolv.conf contents +
#                                     symlink target + resolvectl status
#       network-reachability.txt    - ping gateway / 8.8.8.8 / 1.1.1.1,
#                                     DNS lookup via default and via
#                                     8.8.8.8 directly, HTTP probe of
#                                     archive.ubuntu.com
#
#     Logs (full files, not tails)
#       cloud-init.log              - cloud-init's own module log
#       cloud-init-output.log       - stdout/stderr from cloud-init's
#                                     subprocesses (apt, runcmd, etc.)
#       journal-cloud-config.txt    - cloud-config.service journal
#                                     (sshd ordering targets this unit,
#                                     so its journal is the first place
#                                     to look when boot hangs)
#       journal-cloud-final.txt     - cloud-final.service journal
#                                     (where apt sat for 6 min in the
#                                     prior baseline run)
#
#     Apt / dpkg (the dominant time sink at 362s)
#       apt-config.txt              - `apt-config dump` (mirrors, options)
#       apt-sources.txt             - rendered /etc/apt/sources.list and
#                                     /etc/apt/sources.list.d/* contents
#       apt-history.log             - one entry per apt invocation, with
#                                     start/end timestamps and packages
#       apt-term.log                - apt subprocess output (downloads,
#                                     dpkg messages) keyed to history.log
#       dpkg.log                    - every package state transition with
#                                     ms-precision timestamps
# ---------------------------------------------------------------------------

function Invoke-CloudInitDiagnostics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $VmConfigPath,

        [Parameter(Mandatory)]
        [string] $VmName,

        [Parameter(Mandatory)]
        [string] $Timestamp
    )

    # diagnostics/<vmName>/<timestamp>/ so:
    #   - VmConfigPath is shared across VMs (per the seed ISO convention)
    #     without per-VM dumps colliding
    #   - re-provisioning the same VM (reconcile path) does not overwrite
    #     the headline first-boot capture - idle re-runs land in a new
    #     timestamped folder
    #   - $Timestamp is supplied by the caller (set once per VM in
    #     Invoke-VmCreation as $Vm._diagTimestamp) so console.log from
    #     Start-SerialConsoleCapture and the dumps below land in the
    #     SAME folder for a given run.
    $diagDir = Join-Path $VmConfigPath 'diagnostics'
    $diagDir = Join-Path $diagDir      $VmName
    $diagDir = Join-Path $diagDir      $Timestamp
    if (-not (Test-Path -Path $diagDir -PathType Container)) {
        New-Item -ItemType Directory -Path $diagDir -Force | Out-Null
    }
    Write-Host "  [diag] writing under $diagDir"

    # Ordered so the headline "blame" outputs land first in the log and
    # the most expensive / largest outputs land last. Each value is run
    # under `sh -c '... 2>&1'` so stderr is merged server-side; SSH.NET
    # has no stream-merge option of its own. Single-quotes in the
    # command body are escaped via the standard '\'' dance.
    #
    # Logs are pulled in full (`cat`, not `tail`). cloud-init.log on a
    # slow first boot is a few hundred KB - well within the budget for
    # host-side capture, and the headline 362s of apt activity scrolls
    # past `tail -n 500` so a tail cuts the most interesting region.
    # `journalctl -n 1000` keeps the per-unit journals bounded because
    # those can grow unboundedly across boots.
    # `--no-pager` is mandatory for `systemctl` and `journalctl` over
    # non-interactive SSH; without it they invoke `less` and hang the
    # SSH command indefinitely.
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

        # ---------- SSH-unit state (patch 2 verification) ----------
        # Invoke-BaseImagePatch.ps1 writes a drop-in to both
        # ssh.service.d/ and ssh.socket.d/ that adds
        # After/Wants=cloud-config.service. On boot, systemd reported
        # an ordering cycle involving ssh.socket and resolved it by
        # dropping the cloud-config.service start job, which silently
        # disabled patch 2's protection for that boot. These captures
        # answer:
        #   - is ssh.socket actually enabled on this image?
        #   - is the patch 2 drop-in present and being merged into
        #     the active unit config?
        #   - which target.wants/ symlink controls activation?
        'ssh-units-status.txt'        =
            'systemctl status --no-pager ssh.service ssh.socket'
        # `systemctl cat` prints the unit file PLUS every drop-in
        # systemd applied, so if patch 2's 10-wait-cloud-config.conf
        # is being read, it will appear here. `is-enabled` confirms
        # whether the unit is active in the boot graph at all.
        'ssh-units-config.txt'        =
            'echo "=== systemctl cat ssh.service ===" && ' +
            'systemctl cat ssh.service 2>&1; ' +
            'echo "=== systemctl cat ssh.socket ===" && ' +
            'systemctl cat ssh.socket 2>&1; ' +
            'echo "=== is-enabled ===" && ' +
            'systemctl is-enabled ssh.service ssh.socket 2>&1; ' +
            'echo "=== sockets.target.wants/ ===" && ' +
            'ls -la /etc/systemd/system/sockets.target.wants/ ' +
            '/lib/systemd/system/sockets.target.wants/ 2>&1'

        # ---------- Network (root cause of most slow runs) ----------
        # DNS resolution against Ubuntu mirrors has been the dominant
        # cost in every slow first-boot we've observed - apt-get update
        # waits the full ~90s DNS-timeout budget per source x 4 sources
        # = ~6 minutes before falling back to cached package lists.
        # The captures below distinguish among:
        #   - NAT / routing broken (gateway unreachable, no default
        #     route, NAT rule missing on host)
        #   - Outbound blocked (gateway reachable but 8.8.8.8 / 1.1.1.1
        #     unreachable from the host)
        #   - DNS specifically broken (ICMP succeeds but name lookup
        #     fails; usually resolved.conf pointing at the wrong server,
        #     or systemd-resolved using DHCP-supplied DNS that does not
        #     exist on a NAT-only network)
        'network-interfaces.txt'      =
            'echo "=== ip addr ===" && ip -d addr; ' +
            'echo "=== ip route ===" && ip route; ' +
            'echo "=== ip rule ===" && ip rule'
        # /etc/resolv.conf is a symlink to /run/systemd/resolve/stub-resolv.conf
        # on systemd-resolved systems; print both the symlink target
        # and its contents so an operator can see where resolution
        # actually goes.
        'network-resolv.txt'          =
            'echo "=== /etc/resolv.conf ($(readlink -f /etc/resolv.conf)) ===" && ' +
            'cat /etc/resolv.conf; ' +
            'echo "=== resolvectl status ===" && ' +
            'resolvectl status 2>&1 || echo "resolvectl not available"'
        # Reachability probes. Gateway is derived from the default route
        # so the script does not bake in the host's vNIC subnet. Each
        # ping is capped at -W 2 (per-packet 2s budget) and -c 3 (three
        # packets) so a fully unreachable target costs ~6s, not ~30s.
        # curl --max-time 10 caps the HTTP probe similarly.
        'network-reachability.txt'    =
            'GW=$(ip route show default | awk "{print \$3}" | head -1); ' +
            'echo "=== ping gateway ($GW) ===" && ping -c 3 -W 2 "$GW" 2>&1; ' +
            'echo "=== ping 8.8.8.8 ===" && ping -c 3 -W 2 8.8.8.8 2>&1; ' +
            'echo "=== ping 1.1.1.1 ===" && ping -c 3 -W 2 1.1.1.1 2>&1; ' +
            'echo "=== DNS via default resolver ===" && getent hosts archive.ubuntu.com 2>&1; ' +
            'echo "=== DNS via 8.8.8.8 directly ===" && nslookup archive.ubuntu.com 8.8.8.8 2>&1; ' +
            'echo "=== HTTP to archive.ubuntu.com ===" && ' +
            'curl --max-time 10 -sS -o /dev/null ' +
            '-w "http_code=%{http_code} time_total=%{time_total}\n" ' +
            'http://archive.ubuntu.com/ 2>&1'

        # ---------- Logs (full) ----------
        'cloud-init.log'              = 'sudo cat /var/log/cloud-init.log'
        'cloud-init-output.log'       = 'sudo cat /var/log/cloud-init-output.log'
        'journal-cloud-config.txt'    =
            'sudo journalctl --no-pager -n 1000 -u cloud-config.service'
        'journal-cloud-final.txt'     =
            'sudo journalctl --no-pager -n 1000 -u cloud-final.service'

        # ---------- Apt / dpkg ----------
        # history.log lists every apt invocation with its packages and
        # start/end timestamps - the headline source for "what did apt
        # spend 6 minutes doing". term.log carries the corresponding
        # apt subprocess output (download + dpkg lines). dpkg.log
        # records every package state transition with millisecond
        # timestamps and is the authoritative "who installed what
        # when" record.
        'apt-config.txt'              = 'apt-config dump'
        'apt-sources.txt'             =
            'echo "=== /etc/apt/sources.list ===" && ' +
            'cat /etc/apt/sources.list 2>/dev/null; ' +
            'for f in /etc/apt/sources.list.d/*; do ' +
            'echo "=== $f ==="; cat "$f"; done'
        'apt-history.log'             = 'sudo cat /var/log/apt/history.log'
        'apt-term.log'                = 'sudo cat /var/log/apt/term.log'
        'dpkg.log'                    = 'sudo cat /var/log/dpkg.log'
    }

    foreach ($entry in $diagCommands.GetEnumerator()) {
        $outPath = Join-Path $diagDir $entry.Key
        Write-Host "  [diag] $($entry.Value) -> $outPath"
        $remoteCmd = "sh -c " + "'" + ($entry.Value -replace "'", "'\''") + " 2>&1'"
        $result = Invoke-SshClientCommand -SshClient $SshClient -Command $remoteCmd
        Set-Content -Path $outPath -Value $result.Output -Encoding UTF8
    }
}
