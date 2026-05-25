<#
.NOTES
    Dot-sourced by provision.ps1. Shares state with the other
    Phase-Timing helpers through the script-scoped variable
    $script:PhaseTimings (declared inline below). Because all three
    helper files are dot-sourced into provision.ps1's scope, they
    operate on the same list.
#>

# Record shape:
#   { Order; Name; Status; ElapsedMs }
#   Status values: 'NotStarted' | 'Running' | 'OK' | 'Failed'
# Order preserves declaration order so the report reads top-to-bottom
# in the same sequence the operator wrote phases.
#
# Declared here (not in a separate file) because it is the natural
# anchor for the timing state: every flow has to call
# Initialize-PhaseTimings before the other two helpers do anything,
# so binding the variable's lifetime to this file keeps the contract
# "init first" structurally visible.
$script:PhaseTimings = $null

# ---------------------------------------------------------------------------
# Initialize-PhaseTimings
#   Declares the full set of phases up-front so the report can list every
#   phase (including ones that never ran because an earlier phase failed)
#   in a stable order. Re-initialising clears any prior state - safe to
#   call again across nested provision runs within a single PS session.
# ---------------------------------------------------------------------------

function Initialize-PhaseTimings {
    [CmdletBinding()]
    param(
        # Phase display names, in the order they will run. Each name is
        # also the lookup key used by Invoke-WithPhaseTimer.
        [Parameter(Mandatory)]
        [string[]] $Phases
    )

    $script:PhaseTimings =
        [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Phases.Count; $i++) {
        $script:PhaseTimings.Add([pscustomobject]@{
            Order     = $i
            Name      = $Phases[$i]
            Status    = 'NotStarted'
            ElapsedMs = $null
        })
    }
}
