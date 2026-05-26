BeforeAll {
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\timing\Initialize-PhaseTimings.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\timing\Add-SubStepDuration.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\timing\Invoke-WithSubStepTimer.ps1"

    # Manual scan + distinct param names. See sibling
    # Add-SubStepDuration.Tests.ps1 for the rationale (Pester 5 auto-
    # variable shadowing).
    function Get-SubStepRecord {
        param([string] $ParentName, [string] $StepName)
        $state = Get-Variable -Scope Script -Name PhaseTimings -ValueOnly
        foreach ($r in $state) {
            if ($r.Name -eq $StepName -and $r.Parent -eq $ParentName) {
                return $r
            }
        }
        return $null
    }
}

Describe 'Invoke-WithSubStepTimer' {

    BeforeEach {
        Initialize-PhaseTimings -Phases @(
            @{ Name = 'P'; SubSteps = @('s1') }
        )
    }

    It 'invokes the action and records elapsed time under the sub-step on success' {
        # Use a script-scope flag because the action runs in its own
        # scope; a plain $ran assignment inside the action would not
        # be visible to the outer test scope.
        $script:_actionRan = $false
        Invoke-WithSubStepTimer -Parent 'P' -Name 's1' -Action {
            $script:_actionRan = $true
        }

        $script:_actionRan | Should -Be $true
        $r = Get-SubStepRecord -ParentName 'P' -StepName 's1'
        $r.Status    | Should -Be 'OK'
        $r.ElapsedMs | Should -BeGreaterOrEqual 0
    }

    It 're-throws the exception and marks the sub-step Failed when the action throws' {
        # Status must be Failed (sticky) AND ElapsedMs must reflect the
        # partial duration - the report still needs to show how long
        # the failing sub-step ran.
        { Invoke-WithSubStepTimer -Parent 'P' -Name 's1' -Action {
            throw 'kaboom'
        } } | Should -Throw 'kaboom'

        $r = Get-SubStepRecord -ParentName 'P' -StepName 's1'
        $r.Status    | Should -Be 'Failed'
        $r.ElapsedMs | Should -Not -BeNullOrEmpty
    }

    It 'accumulates across multiple calls (per-VM loop semantics)' {
        Invoke-WithSubStepTimer -Parent 'P' -Name 's1' -Action { }
        $before = (Get-SubStepRecord -ParentName 'P' -StepName 's1').ElapsedMs
        Invoke-WithSubStepTimer -Parent 'P' -Name 's1' -Action { }
        $after  = (Get-SubStepRecord -ParentName 'P' -StepName 's1').ElapsedMs

        # Strictly >= is the right guard because either call could
        # legitimately measure 0 ms in a fast environment.
        $after | Should -BeGreaterOrEqual $before
    }
}
