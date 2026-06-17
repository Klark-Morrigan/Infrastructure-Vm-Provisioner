<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1.
#>

# ---------------------------------------------------------------------------
# Format-ElapsedBudgetWithGradient
#   Returns a colour-encoded "<elapsed> / <budget>" string for a polling
#   step that may succeed (within budget) or time out (budget hit). Used by
#   create-vm.ps1's wait-for-SSH tail; lifted into its own helper so the
#   polling loop reads as flow control rather than ANSI math.
#
#   Encoding:
#     - Success: elapsed shifts green -> orange as the ratio of elapsed to
#       budget climbs. The budget itself is uncoloured because we did not
#       hit it; colouring it would compete with the gradient for the eye.
#     - Timeout: BOTH numbers go red. Elapsed because that is the time we
#       burned; budget because that is what we ran out of. Two reds carry
#       the "we hit the cap" reading from a metre away.
#
#   Returns a plain string the caller writes via Write-Host. Pure transform:
#   no Write-Host, no Get-Date, no side effects. That keeps the helper
#   trivially testable and lets the caller decide how (and whether) to
#   render the result.
# ---------------------------------------------------------------------------
function Format-ElapsedBudgetWithGradient {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # Seconds the polling step actually spent.
        [Parameter(Mandatory)]
        [int] $ElapsedSeconds,

        # Seconds the polling step was budgeted for.
        [Parameter(Mandatory)]
        [int] $BudgetSeconds,

        # $true when the polling step exited via the success path,
        # $false when it timed out.
        [Parameter(Mandatory)]
        [bool] $Succeeded
    )

    if ($Succeeded) {
        # Clamp to 1.0 in case a slow poll iteration carried elapsed
        # microseconds past budget at the very edge - the gradient
        # stays well-defined and the success colour holds.
        $ratio = [Math]::Min(1.0,
            [double]$ElapsedSeconds / [double]$BudgetSeconds)
        # Linear blend (80,200,80) -> (255,165,0): green at ratio 0,
        # orange at ratio 1.
        $r = [int][Math]::Round( 80 + $ratio * (255 -  80))
        $g = [int][Math]::Round(200 + $ratio * (165 - 200))
        $b = [int][Math]::Round( 80 + $ratio * (  0 -  80))
        $elapsedColored = "`e[38;2;$r;$g;${b}m${ElapsedSeconds}s`e[0m"
        $budgetColored  = "${BudgetSeconds}s"
    }
    else {
        $red            = '38;2;220;70;70'
        $elapsedColored = "`e[${red}m${ElapsedSeconds}s`e[0m"
        $budgetColored  = "`e[${red}m${BudgetSeconds}s`e[0m"
    }
    "$elapsedColored / $budgetColored"
}
