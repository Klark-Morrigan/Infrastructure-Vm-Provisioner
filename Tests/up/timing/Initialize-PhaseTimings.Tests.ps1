BeforeAll {
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\timing\Initialize-PhaseTimings.ps1"
    # Invoke-WithPhaseTimer is needed by the "clears prior state"
    # case to seed a record's state before re-init. Loaded here so
    # the test file stays self-contained.
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\timing\Invoke-WithPhaseTimer.ps1"
}

Describe 'Initialize-PhaseTimings' {

    It 'creates one record per declared phase, all NotStarted' {
        Initialize-PhaseTimings -Phases @('A', 'B', 'C')

        # State lives in the dot-source scope (script scope), so read
        # it directly rather than guessing a session-state binding.
        $state = Get-Variable -Scope Script -Name PhaseTimings -ValueOnly
        $state.Count        | Should -Be 3
        $state[0].Name      | Should -Be 'A'
        $state[0].Order     | Should -Be 0
        $state[0].Status    | Should -Be 'NotStarted'
        $state[0].ElapsedMs | Should -BeNullOrEmpty
        ($state | ForEach-Object Status) | Should -Be @(
            'NotStarted', 'NotStarted', 'NotStarted'
        )
    }

    It 'clears prior state on re-init' {
        Initialize-PhaseTimings -Phases @('A', 'B')
        Invoke-WithPhaseTimer -Name 'A' -Action { }

        Initialize-PhaseTimings -Phases @('X')

        $state = Get-Variable -Scope Script -Name PhaseTimings -ValueOnly
        $state.Count   | Should -Be 1
        $state[0].Name | Should -Be 'X'
    }
}
