<#
.NOTES
    Dot-sourced by provision.ps1. Shares state with the other
    Phase-Timing helpers through the script-scoped variable
    $script:PhaseTimings (declared inline below). Because every
    Phase-Timing helper is dot-sourced into provision.ps1's scope,
    they operate on the same list.
#>

# Record shape:
#   { Order; Name; Status; ElapsedMs; Parent }
#   Status values: 'NotStarted' | 'Running' | 'OK' | 'Failed'
#   Parent is $null for top-level phases, or the parent phase's Name
#   for sub-steps. Order preserves declaration order across the WHOLE
#   list (top-level + sub-steps interleaved) so the report renderer
#   can do a single sorted walk and still group sub-steps under their
#   parents.
#
# Declared here (not in a separate file) because it is the natural
# anchor for the timing state: every flow has to call
# Initialize-PhaseTimings before the other helpers do anything, so
# binding the variable's lifetime to this file keeps the contract
# "init first" structurally visible.
$script:PhaseTimings = $null

# ---------------------------------------------------------------------------
# Initialize-PhaseTimings
#   Declares the full set of phases up-front so the report can list every
#   phase (including ones that never ran because an earlier phase failed)
#   in a stable order. Re-initialising clears any prior state - safe to
#   call again across nested provision runs within a single PS session.
#
#   Each item in -Phases is either:
#
#     * a plain string                    - declares a top-level phase.
#
#     * a hashtable @{ Name = '...';      - declares a top-level phase
#                      SubSteps = @(..) }   AND its known sub-steps. The
#                                            sub-steps render indented
#                                            under the parent in the
#                                            report. Pre-declaring is
#                                            optional: a sub-step that
#                                            first appears via a sub-step
#                                            timer call is lazily added
#                                            with status NotStarted ->
#                                            running -> OK / Failed.
#                                            Pre-declaration is preferred
#                                            for sub-steps that may NOT
#                                            execute in a given run (e.g.
#                                            'files' when no VM has a
#                                            files array) so the report
#                                            still shows them as SKIPPED
#                                            rather than omitting them.
# ---------------------------------------------------------------------------

function Initialize-PhaseTimings {
    [CmdletBinding()]
    param(
        # Phase declarations, in the order they will run. Strings = bare
        # top-level phase. Hashtables = top-level phase + pre-declared
        # sub-steps.
        [Parameter(Mandatory)]
        [object[]] $Phases
    )

    $script:PhaseTimings =
        [System.Collections.Generic.List[object]]::new()

    # Single running counter shared across top-level + sub-step entries
    # so the renderer can sort by Order and emit the report in
    # declaration sequence regardless of how the two kinds were
    # interleaved here.
    $order = 0

    foreach ($item in $Phases) {
        if ($item -is [hashtable]) {
            $name     = [string]$item['Name']
            $subSteps = @()
            if ($item.ContainsKey('SubSteps') -and $null -ne $item['SubSteps']) {
                $subSteps = @($item['SubSteps'])
            }
        }
        else {
            $name     = [string]$item
            $subSteps = @()
        }

        if ([string]::IsNullOrWhiteSpace($name)) {
            throw "Initialize-PhaseTimings: phase entry has no Name."
        }

        $script:PhaseTimings.Add([pscustomobject]@{
            Order     = $order
            Name      = $name
            Status    = 'NotStarted'
            ElapsedMs = $null
            Parent    = $null
        })
        $order++

        foreach ($subName in $subSteps) {
            $subNameStr = [string]$subName
            if ([string]::IsNullOrWhiteSpace($subNameStr)) {
                throw (
                    "Initialize-PhaseTimings: phase '$name' has an empty " +
                    "sub-step name."
                )
            }
            $script:PhaseTimings.Add([pscustomobject]@{
                Order     = $order
                Name      = $subNameStr
                Status    = 'NotStarted'
                ElapsedMs = $null
                Parent    = $name
            })
            $order++
        }
    }
}
