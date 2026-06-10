<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1.
#>

# ---------------------------------------------------------------------------
# Wait-VmSshBannerReachable
#   Polls a TCP endpoint until both the bare TCP probe (Test-VmSshPort) AND
#   the SSH banner read (Test-SshBanner) succeed, or the deadline expires.
#   Returns $true on success, $false on timeout. Throws when the per-poll
#   $OnPoll callback throws (the caller decides whether to abort - typical
#   use is a "VM no longer Running" early exit).
#
#   Why the banner gate (not just TCP):
#     Through an SSH.NET ForwardedPortLocal tunnel, TCP accepts the moment
#     the local listener binds - bare TCP probes succeed instantly even
#     when the far-side workload is not yet serving SSH. Test-SshBanner
#     reads the first four bytes and only returns $true when they start
#     with "SSH-", which confirms the workload's sshd has actually
#     replied. Direct probes against a known-good IP take the same banner
#     check uniformly; the cost is one extra round trip per success.
#
#   What the caller still owns:
#     - The progress dot per iteration AND the elapsed-time tail on
#       success / failure. -OnPoll is called once per "not ready yet"
#       iteration so callers paint dots or log structured events
#       without the helper coupling to a specific UI.
#     - The throw / Write-Host wording after a timeout. The helper
#       returns a bool so callers can compose a domain-specific
#       message (e.g. "SSH on '<vm>' did not become reachable ...")
#       around it.
# ---------------------------------------------------------------------------
function Wait-VmSshBannerReachable {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        # IP / hostname to probe. For workloads behind a NAT router this
        # is the loopback endpoint of an SSH.NET ForwardedPortLocal; for
        # routers and pre-feature-53 callers it is the VM's own IP.
        [Parameter(Mandatory)]
        [string] $IpAddress,

        [Parameter(Mandatory)]
        [int] $Port,

        # Hard deadline. The loop body runs while (Get-Date) -lt
        # $Deadline; success on the iteration that crosses the
        # deadline is still recorded. Passing a deadline already in
        # the past skips the body and returns $false immediately.
        [Parameter(Mandatory)]
        [datetime] $Deadline,

        # Cadence between iterations when neither probe succeeds.
        [Parameter()]
        [int] $PollIntervalSeconds = 10,

        # Fired once per "not ready yet" iteration BEFORE the probe.
        # Used by callers to enforce side-conditions (e.g. checking
        # Hyper-V's Get-VM state for an early abort) without the
        # helper having to know about the caller's domain. The
        # scriptblock should throw to abort the loop; a clean return
        # lets the next iteration proceed.
        [Parameter()]
        [scriptblock] $OnPoll
    )

    while ((Get-Date) -lt $Deadline) {
        if ($null -ne $OnPoll) { & $OnPoll }

        if (Test-VmSshPort -IpAddress $IpAddress -Port $Port) {
            if (Test-SshBanner -IpAddress $IpAddress -Port $Port) {
                return $true
            }
        }

        Write-Host '.' -NoNewline
        Start-Sleep -Seconds $PollIntervalSeconds
    }

    return $false
}
