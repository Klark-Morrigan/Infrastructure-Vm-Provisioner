<#
.NOTES
    Do not run this file directly. Dot-sourced by Import-PreflightFunctions.ps1.
#>

# ---------------------------------------------------------------------------
# Test-ElevatedSession
#   Preflight check 0: the session is elevated. Hyper-V and Get-Net* cmdlets
#   return nothing, silently, for a session that is not, which every later
#   check would misread as "switch missing". A FAIL here ends the preflight,
#   so the operator gets the one real cause instead of that cascade.
#
#   The answer itself comes from Test-IsCurrentSessionElevated, kept apart so a
#   test can decide it.
# ---------------------------------------------------------------------------

function Test-ElevatedSession {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $label = 'PowerShell session is elevated'

    if (-not (Test-IsCurrentSessionElevated)) {
        return New-PreflightFinding `
            -Status FAIL `
            -Label $label `
            -Detail (
                "Hyper-V and Get-Net* cmdlets need admin (or Hyper-V Administrators group). " +
                "Re-run from an elevated PowerShell.")
    }

    New-PreflightFinding `
        -Status PASS `
        -Label $label `
        -Detail 'Hyper-V cmdlets are reachable.'
}
