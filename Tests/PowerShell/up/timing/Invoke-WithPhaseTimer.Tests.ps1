BeforeAll {
    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\up\timing\Initialize-PhaseTimings.ps1"
    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\up\timing\Invoke-WithPhaseTimer.ps1"
}

Describe 'Invoke-WithPhaseTimer' {

    BeforeEach {
        # Re-init for each test so prior state never leaks across cases.
        Initialize-PhaseTimings -Phases @('A', 'B', 'C')
    }

    It 'records OK and a non-null duration on clean return' {
        Invoke-WithPhaseTimer -Name 'A' -Action {
            Start-Sleep -Milliseconds 10
        }
        $state = Get-Variable -Scope Script -Name PhaseTimings -ValueOnly
        $a = $state | Where-Object Name -EQ 'A'
        $a.Status    | Should -Be 'OK'
        $a.ElapsedMs | Should -BeGreaterOrEqual 0
    }

    It 'records Failed AND a duration when the action throws, then re-throws' {
        { Invoke-WithPhaseTimer -Name 'B' -Action {
            Start-Sleep -Milliseconds 5
            throw 'boom'
        } } | Should -Throw -ExpectedMessage 'boom'
        $state = Get-Variable -Scope Script -Name PhaseTimings -ValueOnly
        $b = $state | Where-Object Name -EQ 'B'
        $b.Status    | Should -Be 'Failed'
        $b.ElapsedMs | Should -BeGreaterOrEqual 0
    }

    It 'leaves later phases NotStarted when an earlier phase throws' {
        { Invoke-WithPhaseTimer -Name 'A' -Action { throw 'x' } } |
            Should -Throw
        $state = Get-Variable -Scope Script -Name PhaseTimings -ValueOnly
        ($state | Where-Object Name -EQ 'B').Status | Should -Be 'NotStarted'
        ($state | Where-Object Name -EQ 'C').Status | Should -Be 'NotStarted'
    }

    It 'throws on an unknown phase name' {
        { Invoke-WithPhaseTimer -Name 'NoSuch' -Action { } } |
            Should -Throw -ExpectedMessage "*NoSuch*was not declared*"
    }

    It 'throws when Initialize was never called' {
        Set-Variable -Scope Script -Name PhaseTimings -Value $null
        { Invoke-WithPhaseTimer -Name 'A' -Action { } } |
            Should -Throw -ExpectedMessage '*Initialize-PhaseTimings has not been called*'
    }
}
