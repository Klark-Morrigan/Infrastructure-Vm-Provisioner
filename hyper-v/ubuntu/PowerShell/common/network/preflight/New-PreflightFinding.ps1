<#
.NOTES
    Do not run this file directly. Dot-sourced by Import-PreflightFunctions.ps1.
#>

# ---------------------------------------------------------------------------
# New-PreflightFinding
#   The one place a preflight finding takes its shape. Every check returns
#   findings and the orchestrator prints and counts them, so a check that
#   built its own object could misspell a property or a status and have it
#   print in no colour and never count as a FAIL.
# ---------------------------------------------------------------------------

function New-PreflightFinding {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('PASS', 'WARN', 'FAIL')]
        [string] $Status,

        # What was checked, worded the same whichever way it went.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Label,

        # What was found and, on a WARN or FAIL, what to do about it.
        [string] $Detail
    )

    [PSCustomObject]@{
        Status = $Status
        Label = $Label
        Detail = $Detail
    }
}
