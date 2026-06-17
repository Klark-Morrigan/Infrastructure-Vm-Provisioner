<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1.
#>

# ---------------------------------------------------------------------------
# Wait-CloudInitFinished
#   Polls `cloud-init status` over an already-open SSH session every
#   $PollIntervalSeconds, printing the current status with an elapsed
#   counter so the operator sees the line move instead of staring at a
#   silent multi-minute hang. Returns an object with the final status:
#     - ExitStatus: 0 when cloud-init reaches `done` / `disabled`,
#                   1 when it reaches `error`,
#                   124 when the $BudgetSeconds wall-clock is exhausted
#                   (matches GNU timeout's exit code so existing
#                    branches that check for non-zero "wait completed
#                    but cloud-init flagged something" keep working).
#     - Output:     the last status string we observed.
#
#   The previous shape was a single blocking
#   `timeout NN cloud-init status --wait`. The SSH command sat without
#   output for the full duration; an operator could not tell whether
#   cloud-init was making progress or stuck. The poll is logically
#   the same gate (block until cloud-init reaches a terminal state)
#   but with per-iteration visibility.
#
#   No early-return on identical statuses: the loop deliberately
#   prints a heartbeat every poll even when status has not changed,
#   because the headline failure mode the line existed to defend
#   against was "is anything still happening?" - a frozen counter is
#   the diagnostic signal.
# ---------------------------------------------------------------------------

function Wait-CloudInitFinished {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $VmName,

        # Wall-clock cap on the poll loop. Set deliberately wider than
        # the longest first-boot we have observed (~6 min on the
        # noble Azure image) so a genuinely slow boot does not turn
        # into a phantom failure.
        [int] $BudgetSeconds = 600,

        # Cadence between cloud-init status probes. 5s is the smallest
        # value that does not flood the SSH session for a 6-minute
        # boot (~70 lines of output) while still feeling responsive.
        [int] $PollIntervalSeconds = 5,

        # Wrap the dot stream after this many dots so a slow boot
        # does not produce one long terminal-overflowing line. 60
        # dots at the 5s default cadence = 5 minutes per visual
        # row, which lines up with cloud-init's typical first-boot
        # apt window. The wrap inserts a newline + 4-space indent
        # so each continuation line stays aligned with the
        # orchestrator's "  Waiting for cloud-init ..." header.
        [int] $WrapAfterDots = 60
    )

    # Output style: dots streamed for every "nothing changed" poll,
    # inline " [<status>]" injected on a status transition. Matches
    # the SSH-polling cadence in create-vm.ps1. The caller stamps an
    # elapsed/budget summary on the same line after we return; the
    # returned object carries ElapsedSeconds + BudgetSeconds so the
    # caller does not have to recompute them.
    #
    # Wrap the dot stream every $WrapAfterDots polls so a slow boot
    # does not produce a 100+ char single line that overflows the
    # terminal. The wrap injects a newline + 4-space indent + a brief
    # elapsed-seconds marker so the next line is easy to align
    # visually against the rest of the post-provisioning log.
    $started    = Get-Date
    $lastStatus = $null
    $dotsOnLine = 0
    while ($true) {
        $elapsed = [int]((Get-Date) - $started).TotalSeconds
        $statusResult = Invoke-SshClientCommand -SshClient $SshClient `
            -Command 'cloud-init status 2>&1'
        # Parse: e.g. "status: running" / "status: done" /
        # "status: error" / "status: disabled" (or "not run" early
        # on). Lowercased + trimmed for the match below.
        $statusLine = (($statusResult.Output -join "`n") `
            -split "`n" | Where-Object { $_ -match 'status:' } |
            Select-Object -First 1)
        $status = if ($statusLine) {
            ($statusLine -replace '.*status:\s*', '').Trim().ToLower()
        } else { 'unknown' }

        if ($status -in @('done', 'error', 'disabled')) {
            $exitCode = if ($status -eq 'error') { 1 } else { 0 }
            return [PSCustomObject]@{
                ExitStatus     = $exitCode
                Output         = $status
                ElapsedSeconds = $elapsed
                BudgetSeconds  = $BudgetSeconds
            }
        }
        if ($elapsed -ge $BudgetSeconds) {
            return [PSCustomObject]@{
                ExitStatus     = 124
                Output         = $status
                ElapsedSeconds = $elapsed
                BudgetSeconds  = $BudgetSeconds
            }
        }

        # Useful info on transition, dot otherwise. First iteration's
        # $lastStatus is $null, so we suppress the initial transition
        # marker too - the caller's header (e.g. "Waiting for
        # cloud-init to finish ...") already implies "status is
        # whatever it is", so we start with a dot.
        if ($null -eq $lastStatus -or $status -eq $lastStatus) {
            Write-Host '.' -NoNewline
            $dotsOnLine++
            if ($dotsOnLine -ge $WrapAfterDots) {
                # Newline + indent so the next dot stream visually
                # aligns under the orchestrator's header.
                Write-Host ''
                Write-Host '    ' -NoNewline
                $dotsOnLine = 0
            }
        } else {
            Write-Host " [$status]" -NoNewline
            # Reset wrap counter on a transition: the inline status
            # marker already broke the visual cadence, so let the
            # next batch of dots start fresh.
            $dotsOnLine = 0
        }
        $lastStatus = $status

        Start-Sleep -Seconds $PollIntervalSeconds
    }
}
