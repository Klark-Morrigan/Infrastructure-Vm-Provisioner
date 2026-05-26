<#
.NOTES
    Dot-sourced by provision.ps1 after Initialize-PhaseTimings.ps1
    (which declares $script:PhaseTimings). Reads and updates that
    list via the dot-source scope; no direct dependency on the
    other Phase-Timing files beyond the shared variable contract.
#>

# ---------------------------------------------------------------------------
# Invoke-WithPhaseTimer
#   Wraps -Action in a stopwatch, recording the elapsed wall-clock time
#   under the phase's record AND its terminal status (OK on clean
#   return, Failed on thrown exception). Exceptions propagate to the
#   caller so the existing provisioning control flow is unchanged - the
#   timer just observes; it does not swallow.
# ---------------------------------------------------------------------------

function Invoke-WithPhaseTimer {
    [CmdletBinding()]
    param(
        # Must match a Name passed to Initialize-PhaseTimings. Unknown
        # names throw rather than silently no-op so a typo in
        # provision.ps1 fails loudly at the first phase boundary.
        [Parameter(Mandatory)] [string] $Name,

        [Parameter(Mandatory)] [scriptblock] $Action
    )

    if ($null -eq $script:PhaseTimings) {
        throw ("Invoke-WithPhaseTimer: Initialize-PhaseTimings has not " +
            "been called.")
    }
    # Filter to top-level entries (Parent -eq $null) so a sub-step that
    # happens to share its name with a top-level phase does not shadow
    # this lookup. Sub-step timing goes through Invoke-WithSubStepTimer
    # / Add-SubStepDuration, not this helper.
    # Local name (not $matches, which is a PowerShell automatic).
    $candidates = @($script:PhaseTimings | Where-Object {
        $_.Name -eq $Name -and $null -eq $_.Parent
    })
    $record = if ($candidates.Count -gt 0) { $candidates[0] } else { $null }
    if ($null -eq $record) {
        throw ("Invoke-WithPhaseTimer: phase '$Name' was not declared " +
            "via Initialize-PhaseTimings.")
    }
    $record.Status = 'Running'

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $Action
        $sw.Stop()
        $record.ElapsedMs = $sw.ElapsedMilliseconds
        $record.Status    = 'OK'
    }
    catch {
        # Capture the partial duration before re-throwing - the report
        # still needs to show how long the failing phase ran. Status
        # set first so a Write-PhaseTimingReport call from a finally
        # block sees the correct terminal state.
        $sw.Stop()
        $record.ElapsedMs = $sw.ElapsedMilliseconds
        $record.Status    = 'Failed'
        throw
    }
}
