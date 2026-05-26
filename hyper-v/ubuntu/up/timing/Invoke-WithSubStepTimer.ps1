<#
.NOTES
    Dot-sourced by provision.ps1 after Initialize-PhaseTimings.ps1 and
    Add-SubStepDuration.ps1 (which it builds on top of).
#>

# ---------------------------------------------------------------------------
# Invoke-WithSubStepTimer
#   Stopwatch wrapper for the common case: "run this scriptblock and
#   accumulate its wall-clock time under a sub-step of the given
#   parent phase". Mirrors Invoke-WithPhaseTimer's contract on the
#   top-level side - the action runs as-is, any exception propagates,
#   and the elapsed time is recorded even on failure.
#
#   Multi-call accumulation is the headline behaviour: post-provisioning
#   runs in a per-VM loop, so the same sub-step (e.g. 'files',
#   'cloud-init wait') gets timed once per VM. Each call adds to the
#   running total under that sub-step's record. See Add-SubStepDuration
#   for the status-stickiness contract.
#
#   This is a thin wrapper - the actual list mutation lives in
#   Add-SubStepDuration so the lazy-registration + sticky-status logic
#   has exactly one implementation regardless of whether the caller
#   measured the work itself or delegated to this helper.
# ---------------------------------------------------------------------------

function Invoke-WithSubStepTimer {
    [CmdletBinding()]
    param(
        # Parent top-level phase name. Must already be declared via
        # Initialize-PhaseTimings (Add-SubStepDuration enforces this).
        [Parameter(Mandatory)] [string] $Parent,

        # Sub-step display name. Unique within (Parent, *). Lazily
        # created on first contact if it was not pre-declared.
        [Parameter(Mandatory)] [string] $Name,

        [Parameter(Mandatory)] [scriptblock] $Action
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $Action
        $sw.Stop()
        Add-SubStepDuration `
            -Parent    $Parent `
            -Name      $Name `
            -ElapsedMs $sw.ElapsedMilliseconds
    }
    catch {
        # Capture the partial duration before re-throwing - the report
        # still needs to show how long the failing sub-step ran. The
        # -Failed switch makes the status stickily Failed even if a
        # subsequent VM's iteration of the same sub-step succeeds.
        $sw.Stop()
        Add-SubStepDuration `
            -Parent    $Parent `
            -Name      $Name `
            -ElapsedMs $sw.ElapsedMilliseconds `
            -Failed
        throw
    }
}
