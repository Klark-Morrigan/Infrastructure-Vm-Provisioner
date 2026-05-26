BeforeAll {
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\timing\Initialize-PhaseTimings.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\timing\Invoke-WithPhaseTimer.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\timing\Add-SubStepDuration.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\timing\Invoke-WithSubStepTimer.ps1"
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

    Context 'sub-step rendering' {

        BeforeEach {
            Initialize-PhaseTimings -Phases @(
                @{ Name = 'Post-provisioning'; SubSteps = @('cloud-init wait', 'files') }
            )
            Invoke-WithPhaseTimer   -Name 'Post-provisioning' -Action {
                Invoke-WithSubStepTimer -Parent 'Post-provisioning' -Name 'cloud-init wait' -Action {}
                Invoke-WithSubStepTimer -Parent 'Post-provisioning' -Name 'files'           -Action {}
            }
        }

        It 'renders sub-step rows indented under the parent' {
            $output = (Write-PhaseTimingReport 6>&1 | Out-String) -split "`r?`n"

            # The parent row starts with two leading spaces (the standard
            # column indent) then the parent name. The sub-step row
            # starts with two MORE spaces (the sub-step indent) before
            # the name. Matching on the prefix is the cleanest signal
            # that the hierarchy renders correctly.
            @($output | Where-Object {
                $_ -match '^  Post-provisioning' }).Count |
                Should -Be 1
            @($output | Where-Object {
                $_ -match '^    cloud-init wait' }).Count |
                Should -Be 1
            @($output | Where-Object {
                $_ -match '^    files' }).Count |
                Should -Be 1
        }

        It 'sums only top-level phases into total observed (sub-steps not double-counted)' {
            # Synthesise concrete durations so the assertion is exact.
            $state = Get-Variable -Scope Script -Name PhaseTimings -ValueOnly
            foreach ($r in $state) {
                if ($r.Name -eq 'Post-provisioning')          { $r.ElapsedMs = 1000 }
                if ($r.Name -eq 'cloud-init wait')            { $r.ElapsedMs = 400 }
                if ($r.Name -eq 'files')                      { $r.ElapsedMs = 200 }
            }

            $output = (Write-PhaseTimingReport 6>&1 | Out-String) -split "`r?`n"
            $totalLine = @($output | Where-Object { $_ -match 'total observed' })[0]

            # Top-level contribution is 1000 ms = 1.00 s. Sub-step time
            # is already inside the parent's measured wall-clock; adding
            # it to the total would double-count it.
            $totalLine | Should -Match '1\.00 s'
        }
    }
}
