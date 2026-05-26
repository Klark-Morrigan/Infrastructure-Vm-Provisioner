<#
.NOTES
    Dot-sourced by provision.ps1 after Initialize-PhaseTimings.ps1
    (which declares $script:PhaseTimings). Reads and updates that list
    via the dot-source scope.
#>

# ---------------------------------------------------------------------------
# Add-SubStepDuration
#   Low-level primitive: accumulates -ElapsedMs into the sub-step record
#   named -Name under parent phase -Parent. Designed for callers that
#   already measured the work themselves (e.g. the reconciler reports
#   per-provider elapsed time through a callback) and just need to feed
#   the result into the timing system without wrapping the work itself
#   in a stopwatch.
#
#   For the common "wrap this scriptblock in a stopwatch" case use
#   Invoke-WithSubStepTimer, which is built on top of this primitive.
#
#   Accumulation semantics:
#     - ElapsedMs is additive across multiple calls for the same
#       (Parent, Name). This is the whole point of the sub-step model:
#       the per-VM loops dispatch the same sub-step (e.g. 'files')
#       multiple times, and the report shows the total time spent in
#       that sub-step across all VMs.
#     - Status transitions:
#         NotStarted -> OK              (first successful call)
#         NotStarted -> Failed          (first failed call)
#         OK         -> Failed          (later failure - sticky)
#         Failed     -> Failed          (sticky; later success does
#                                        NOT clear the failure flag,
#                                        so the report still flags the
#                                        bad run)
#     - Lazy registration: if the (Parent, Name) sub-step was not
#       pre-declared via Initialize-PhaseTimings, it is appended to the
#       end of the list with Order placed just after the parent's other
#       sub-steps. Pre-declaring is preferred for sub-steps that may
#       skip a run (so they appear as SKIPPED rather than absent) but
#       dynamic-discovery sub-steps (e.g. one per registered provider)
#       benefit from the lazy path.
# ---------------------------------------------------------------------------

function Add-SubStepDuration {
    [CmdletBinding()]
    param(
        # Name of the parent top-level phase. Must already be declared
        # by Initialize-PhaseTimings - the sub-step ties to a real
        # parent record so the renderer can group correctly.
        [Parameter(Mandatory)] [string] $Parent,

        # Sub-step display name. Unique within (Parent, *).
        [Parameter(Mandatory)] [string] $Name,

        # Milliseconds to add to the sub-step's accumulated total.
        [Parameter(Mandatory)] [int64] $ElapsedMs,

        # Switch on when the measured work threw. The sub-step's
        # status becomes Failed (sticky).
        [switch] $Failed
    )

    if ($null -eq $script:PhaseTimings) {
        throw ("Add-SubStepDuration: Initialize-PhaseTimings has not " +
            "been called.")
    }

    # Validate parent exists. Sub-steps without a real parent would
    # render as orphaned rows in the report; surface the typo loudly
    # instead.
    $parentCandidates = @($script:PhaseTimings | Where-Object {
        $_.Name -eq $Parent -and $null -eq $_.Parent
    })
    $parentRecord = if ($parentCandidates.Count -gt 0) {
        $parentCandidates[0]
    } else { $null }
    if ($null -eq $parentRecord) {
        throw ("Add-SubStepDuration: parent phase '$Parent' was not " +
            "declared via Initialize-PhaseTimings.")
    }

    # Locate or lazily create the sub-step record.
    $subStepCandidates = @($script:PhaseTimings | Where-Object {
        $_.Name -eq $Name -and $_.Parent -eq $Parent
    })
    $record = if ($subStepCandidates.Count -gt 0) {
        $subStepCandidates[0]
    } else { $null }

    if ($null -eq $record) {
        # Lazy registration. Place the new sub-step just after the
        # parent's existing sub-steps so it groups correctly in the
        # report. The Order is whatever follows the LAST entry that
        # belongs to this parent (the parent record itself, or one of
        # its sub-steps). Everything else shifts by one so the order
        # stays dense and stable.
        $maxOrderForParent = ($parentRecord.Order)
        foreach ($r in $script:PhaseTimings) {
            if ($r.Parent -eq $Parent -and $r.Order -gt $maxOrderForParent) {
                $maxOrderForParent = $r.Order
            }
        }
        $newOrder = $maxOrderForParent + 1

        # Push every record at or after $newOrder one slot down. Done
        # in-place because $script:PhaseTimings is a single list shared
        # across all helpers.
        foreach ($r in $script:PhaseTimings) {
            if ($r.Order -ge $newOrder) { $r.Order = $r.Order + 1 }
        }

        $record = [pscustomobject]@{
            Order     = $newOrder
            Name      = $Name
            Status    = 'NotStarted'
            ElapsedMs = $null
            Parent    = $Parent
        }
        $script:PhaseTimings.Add($record) | Out-Null
    }

    # Accumulate elapsed. ElapsedMs is $null on first contact so the
    # cast handles both initial and subsequent calls uniformly.
    $current = if ($null -eq $record.ElapsedMs) { 0L } else { [int64]$record.ElapsedMs }
    $record.ElapsedMs = $current + $ElapsedMs

    # Status transition. Failed is sticky once set - a later success
    # against the same sub-step (which can happen across a per-VM loop
    # where one VM fails and the next succeeds) does not clear the
    # flag, so the report still surfaces the bad run.
    if ($Failed) {
        $record.Status = 'Failed'
    }
    elseif ($record.Status -ne 'Failed') {
        $record.Status = 'OK'
    }
}
