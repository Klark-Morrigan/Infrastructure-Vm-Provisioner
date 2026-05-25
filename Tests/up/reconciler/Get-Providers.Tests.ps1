BeforeAll {
    # Get-Providers composes JdkProvider via Get-JdkProvider, which in
    # turn wires scriptblocks that call the JdkProvider.* operations.
    # Provider-Contract.ps1 supplies Assert-ToolchainProvider that the
    # contract test below uses.
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\reconciler\Provider-Contract.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\jdk\JdkProvider.Get-DesiredVersions.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\jdk\JdkProvider.Get-InstalledVersions.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\jdk\JdkProvider.Install-Version.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\jdk\JdkProvider.Uninstall-Version.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\jdk\Get-JdkProvider.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\reconciler\Get-Providers.ps1"

    function New-PlainVm {
        [PSCustomObject]@{
            vmName              = 'node-01'
            _jdkTarballPath     = 'C:\cache\jdk.tar.gz'
            _jdkResolvedVersion = '21.0.6+7'
        }
    }
}

Describe 'Get-Providers' {

    It 'registers the JDK provider as the first (and currently only) entry' {
        # JdkProvider is the earliest-registered provider; future
        # providers append after it so dispatch order stays stable.
        $providers = @(Get-Providers -Vm (New-PlainVm))

        $providers.Count    | Should -Be 1
        $providers[0].Name  | Should -Be 'javaDevKit'
    }

    It 'returns providers that pass Assert-ToolchainProvider' {
        # Shape check: each provider must carry the four scriptblock
        # members the orchestrator dispatches against. Catching a
        # malformed provider here means a regression in Get-JdkProvider
        # fails this test rather than crashing inside the reconciler
        # mid-dispatch on a real VM.
        $providers = @(Get-Providers -Vm (New-PlainVm))
        foreach ($p in $providers) {
            { Assert-ToolchainProvider -Provider $p } | Should -Not -Throw
        }
    }

    It 'returns a value the caller can foreach over without a null guard' {
        # Regression guard: the implementation uses `,@(...)` precisely
        # so the single-provider case still surfaces as an enumerable
        # rather than getting unwrapped to a scalar.
        $count = 0
        foreach ($p in (Get-Providers -Vm (New-PlainVm))) { $count++ }
        $count | Should -Be 1
    }
}
