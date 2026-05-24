BeforeAll {
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\reconciler\Get-Providers.ps1"
}

Describe 'Get-Providers' {

    It 'returns an empty array at step 5 (no providers registered yet)' {
        # Wrap with @() so a future regression that returns $null also
        # fails this assertion (not just a future non-empty registration).
        $providers = @(Get-Providers)
        $providers.Count | Should -Be 0
    }

    It 'returns a value the caller can foreach over without a null guard' {
        # Regression guard: the implementation uses `,@()` precisely so
        # the empty case still surfaces as an enumerable, not $null.
        $count = 0
        foreach ($p in (Get-Providers)) { $count++ }
        $count | Should -Be 0
    }
}
