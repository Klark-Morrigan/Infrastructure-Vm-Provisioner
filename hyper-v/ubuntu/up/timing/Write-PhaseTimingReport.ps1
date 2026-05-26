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
#   Sub-steps render indented two spaces under their parent. The total
#   line sums TOP-LEVEL phases only so sub-step accumulation does not
#   double-count against the parent's own elapsed time.
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

    # Column widths: account for the sub-step indent so the tag column
    # still lines up across mixed top-level and sub-step rows.
    $subStepIndent = '  '
    $effectiveWidths = $script:PhaseTimings | ForEach-Object {
        if ($null -eq $_.Parent) { $_.Name.Length }
        else                     { $_.Name.Length + $subStepIndent.Length }
    }
    $nameWidth = ($effectiveWidths | Measure-Object -Maximum).Maximum

    $color   = 'DarkGreen'
    $banner  = '=== Provisioning timing report ==='
    $divider = '-' * $banner.Length

    Write-Host ''
    Write-Host $banner -ForegroundColor $color

    # Total observed wall-clock counts top-level rows only. Sub-step
    # durations are time *inside* a parent phase; adding them to the
    # parent's own elapsed would double-count.
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
            if ($null -eq $record.Parent) {
                $totalMs += $record.ElapsedMs
            }
        }

        $displayName = if ($null -eq $record.Parent) {
            $record.Name
        } else {
            $subStepIndent + $record.Name
        }

        $line = '  {0}  {1}  {2}' -f
            $displayName.PadRight($nameWidth), $tag, $duration
        Write-Host $line -ForegroundColor $color
    }

    Write-Host ('  ' + $divider) -ForegroundColor $color
    Write-Host ('  total observed: ' + ([string]::Format(
        [cultureinfo]::InvariantCulture,
        '{0,8:F2} s',
        ($totalMs / 1000.0)))) -ForegroundColor $color
    Write-Host $banner -ForegroundColor $color
}
