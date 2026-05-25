<#
.NOTES
    Dot-sourced by provision.ps1 after Initialize-PhaseTimings.ps1
    (which declares $script:PhaseTimings). Read-only consumer of the
    list - never mutates it.
#>

# ---------------------------------------------------------------------------
# Write-PhaseTimingReport
#   Emits a single-color summary listing every declared phase with its
#   status tag and (if it ran) elapsed time. Designed to be called from
#   the outer try/finally in provision.ps1 so the report appears on
#   both success and failure paths.
#
#   Single color (DarkGreen) so the block reads as one summary unit
#   rather than competing with the per-phase [OK] / [FAIL] text markers.
# ---------------------------------------------------------------------------

function Write-PhaseTimingReport {
    [CmdletBinding()]
    param()

    if ($null -eq $script:PhaseTimings -or
        $script:PhaseTimings.Count -eq 0) {
        return
    }

    # Status -> fixed-width tag so the duration column aligns whether
    # the phase passed, failed, or never started.
    $statusTags = @{
        'NotStarted' = '[SKIPPED]'
        'Running'    = '[RUNNING]'
        'OK'         = '[OK]     '
        'Failed'     = '[FAILED] '
    }

    # Pad the name column to the longest declared phase name so the tag
    # column lines up.
    $nameWidth = ($script:PhaseTimings |
        ForEach-Object { $_.Name.Length } |
        Measure-Object -Maximum).Maximum

    $color   = 'DarkGreen'
    $banner  = '=== Provisioning timing report ==='
    $divider = '-' * $banner.Length

    Write-Host ''
    Write-Host $banner -ForegroundColor $color

    $totalMs = 0
    foreach ($record in ($script:PhaseTimings | Sort-Object Order)) {
        $tag = $statusTags[$record.Status]
        if ($null -eq $record.ElapsedMs) {
            $duration = '     -    '
        } else {
            # Invariant culture so '.' is the decimal separator
            # regardless of the operator's regional settings; log
            # output should be parseable the same way on every host.
            $duration = ([string]::Format(
                [cultureinfo]::InvariantCulture,
                '{0,8:F2} s',
                ($record.ElapsedMs / 1000.0)))
            $totalMs += $record.ElapsedMs
        }
        $line = '  {0}  {1}  {2}' -f
            $record.Name.PadRight($nameWidth), $tag, $duration
        Write-Host $line -ForegroundColor $color
    }

    Write-Host ('  ' + $divider) -ForegroundColor $color
    Write-Host ('  total observed: ' + ([string]::Format(
        [cultureinfo]::InvariantCulture,
        '{0,8:F2} s',
        ($totalMs / 1000.0)))) -ForegroundColor $color
    Write-Host $banner -ForegroundColor $color
}
