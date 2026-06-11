<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1.
#>

# ---------------------------------------------------------------------------
# Assert-PreflightFindings
#   Multi-line throw consolidating every FAIL finding into a single
#   operator-facing error. Each finding's Detail is the "what to do"
#   hint so the message is actionable, not just a count. No-op when
#   no FAILs are present (callers don't have to branch).
# ---------------------------------------------------------------------------

function Assert-PreflightFindings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[object]] $Findings,

        [Parameter(Mandatory)]
        [string] $SwitchName
    )

    $fails = @($Findings | Where-Object Status -eq 'FAIL')
    if ($fails.Count -gt 0) {
        $details = ($fails | ForEach-Object {
            "    - $($_.Label): $($_.Detail)"
        }) -join "`n"
        throw (
            "Host network preflight failed for switch '$SwitchName' " +
            "($($fails.Count) FAIL):`n$details"
        )
    }
}
