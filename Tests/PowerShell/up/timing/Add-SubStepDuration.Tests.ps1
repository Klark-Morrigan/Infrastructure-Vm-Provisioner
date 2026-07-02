BeforeAll {
    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\up\timing\Initialize-PhaseTimings.ps1"
    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\up\timing\Add-SubStepDuration.ps1"

    # Test helper uses a manual loop and distinct parameter names because
    # Pester 5 binds some auto-variables in the It scope that, under
    # certain conditions, shadow Where-Object captures from the
    # surrounding function. Imperative scan over the list dodges that
    # entirely.
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

Describe 'Add-SubStepDuration' {

    BeforeEach {
        # Single parent with two pre-declared sub-steps so the lazy-add
        # path can also be exercised against the same parent in other
        # tests below.
        Initialize-PhaseTimings -Phases @(
            @{ Name = 'P'; SubSteps = @('s1') }
        )
    }

    It 'accumulates ElapsedMs across calls into the same sub-step' {
        Add-SubStepDuration -Parent 'P' -Name 's1' -ElapsedMs 100
        Add-SubStepDuration -Parent 'P' -Name 's1' -ElapsedMs 250

        $r = Get-SubStepRecord -ParentName 'P' -StepName 's1'
        $r.ElapsedMs | Should -Be 350
        $r.Status    | Should -Be 'OK'
    }

    It 'flips status to Failed when -Failed is set' {
        Add-SubStepDuration -Parent 'P' -Name 's1' -ElapsedMs 100 -Failed

        (Get-SubStepRecord -ParentName 'P' -StepName 's1').Status | Should -Be 'Failed'
    }

    It 'keeps Failed sticky across a subsequent successful call' {
        # The "one VM failed but the next succeeded" scenario: the
        # report should still flag the bad run.
        Add-SubStepDuration -Parent 'P' -Name 's1' -ElapsedMs 50 -Failed
        Add-SubStepDuration -Parent 'P' -Name 's1' -ElapsedMs 50

        (Get-SubStepRecord -ParentName 'P' -StepName 's1').Status | Should -Be 'Failed'
    }

    It 'lazily registers a sub-step not pre-declared via Initialize-PhaseTimings' {
        Add-SubStepDuration -Parent 'P' -Name 'lazy' -ElapsedMs 42

        $r = Get-SubStepRecord -ParentName 'P' -StepName 'lazy'
        $r              | Should -Not -BeNullOrEmpty
        $r.Parent       | Should -Be 'P'
        $r.ElapsedMs    | Should -Be 42
        $r.Status       | Should -Be 'OK'
    }

    It 'throws when -Parent is not a declared top-level phase' {
        # Sub-steps without a real parent would orphan in the report.
        { Add-SubStepDuration -Parent 'Nope' -Name 's1' -ElapsedMs 10 } |
            Should -Throw '*Nope*was not declared*'
    }

    It 'throws when Initialize-PhaseTimings has not been called' {
        Set-Variable -Scope Script -Name PhaseTimings -Value $null
        { Add-SubStepDuration -Parent 'P' -Name 's1' -ElapsedMs 10 } |
            Should -Throw '*Initialize-PhaseTimings has not been called*'
    }
}
