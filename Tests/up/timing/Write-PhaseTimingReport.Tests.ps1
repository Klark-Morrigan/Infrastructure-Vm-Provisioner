BeforeAll {
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\timing\Initialize-PhaseTimings.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\timing\Invoke-WithPhaseTimer.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\timing\Write-PhaseTimingReport.ps1"
}

Describe 'Write-PhaseTimingReport' {

    BeforeEach {
        Initialize-PhaseTimings -Phases @('A', 'B', 'C')
    }

    It 'emits one line per phase in declared order, marking statuses correctly' {
        Invoke-WithPhaseTimer -Name 'A' -Action { }
        { Invoke-WithPhaseTimer -Name 'B' -Action { throw 'x' } } |
            Should -Throw
        # C left NotStarted

        $output = (Write-PhaseTimingReport 6>&1 | Out-String) -split "`r?`n"

        # @() wraps each Where-Object so .Count works even when a
        # single-element match would otherwise unwrap to a scalar
        # (memory: feedback_pester5_single_match_count).
        @($output | Where-Object {
            $_ -match '\bA\b' -and $_ -match '\[OK\]' }).Count |
            Should -Be 1
        @($output | Where-Object {
            $_ -match '\bB\b' -and $_ -match '\[FAILED\]' }).Count |
            Should -Be 1
        @($output | Where-Object {
            $_ -match '\bC\b' -and $_ -match '\[SKIPPED\]' }).Count |
            Should -Be 1
        @($output | Where-Object {
            $_ -match '^=== Provisioning timing report ===$' }).Count |
            Should -Be 2
        @($output | Where-Object {
            $_ -match 'total observed' }).Count |
            Should -Be 1
    }

    It 'shows a dash duration for SKIPPED phases (no number, no exception)' {
        $output = (Write-PhaseTimingReport 6>&1 | Out-String) -split "`r?`n"
        $skippedLines = @($output | Where-Object { $_ -match '\[SKIPPED\]' })
        $skippedLines.Count | Should -Be 3
        foreach ($l in $skippedLines) {
            $l | Should -Match '-'
        }
    }

    It 'is a no-op when Initialize was never called' {
        Set-Variable -Scope Script -Name PhaseTimings -Value $null
        $output = Write-PhaseTimingReport 6>&1 | Out-String
        $output.Trim() | Should -BeNullOrEmpty
    }
}
