BeforeAll {
    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\up\timing\Initialize-PhaseTimings.ps1"
    # Invoke-WithPhaseTimer is needed by the "clears prior state"
    # case to seed a record's state before re-init. Loaded here so
    # the test file stays self-contained.
    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\up\timing\Invoke-WithPhaseTimer.ps1"
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

    It 'accepts hashtable entries with SubSteps and links each by Parent' {
        # The hashtable form is how provision.ps1 pre-declares known
        # sub-steps so the report can show them as SKIPPED on runs
        # where the work did not apply.
        Initialize-PhaseTimings -Phases @(
            'A',
            @{ Name = 'B'; SubSteps = @('b1', 'b2') },
            'C'
        )

        $state = Get-Variable -Scope Script -Name PhaseTimings -ValueOnly
        $state.Count | Should -Be 5

        # Order field tracks declaration sequence across top-level
        # AND sub-step rows so the renderer can sort once and emit
        # the report in operator-written order.
        $byName = @{}
        foreach ($r in $state) { $byName[$r.Name] = $r }

        $byName['A'].Parent | Should -BeNullOrEmpty
        $byName['B'].Parent | Should -BeNullOrEmpty
        $byName['C'].Parent | Should -BeNullOrEmpty

        $byName['b1'].Parent | Should -Be 'B'
        $byName['b2'].Parent | Should -Be 'B'

        $byName['A'].Order  | Should -BeLessThan $byName['B'].Order
        $byName['B'].Order  | Should -BeLessThan $byName['b1'].Order
        $byName['b1'].Order | Should -BeLessThan $byName['b2'].Order
        $byName['b2'].Order | Should -BeLessThan $byName['C'].Order

        # Every record starts NotStarted regardless of nesting depth.
        ($state | ForEach-Object Status) -join ',' |
            Should -Be 'NotStarted,NotStarted,NotStarted,NotStarted,NotStarted'
    }

    It 'rejects an empty sub-step name with a message naming the parent' {
        { Initialize-PhaseTimings -Phases @(
            @{ Name = 'B'; SubSteps = @('') }
        ) } | Should -Throw "*'B'*empty sub-step*"
    }
}
