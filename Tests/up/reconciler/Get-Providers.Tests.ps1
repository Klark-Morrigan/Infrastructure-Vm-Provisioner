BeforeAll {
    # Get-Providers composes JdkProvider and DotnetSdkProvider via their
    # respective Get-*Provider factories, which in turn wire scriptblocks
    # that call the *Provider.* operations. Provider-Contract.ps1 supplies
    # Assert-ToolchainProvider that the contract test below uses.
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\reconciler\Provider-Contract.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\jdk\JdkProvider.Get-DesiredVersions.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\jdk\JdkProvider.Get-InstalledVersions.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\jdk\JdkProvider.Install-Version.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\jdk\JdkProvider.Uninstall-Version.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\jdk\Get-JdkProvider.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\dotnet\DotnetSdkProvider.Get-DesiredVersions.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\dotnet\DotnetSdkProvider.Get-InstalledVersions.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\dotnet\DotnetSdkProvider.Install-Version.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\dotnet\DotnetSdkProvider.Uninstall-Version.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\dotnet\Get-DotnetSdkProvider.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\dotnet\DotnetToolsProvider.Get-DesiredVersions.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\dotnet\DotnetToolsProvider.Get-InstalledVersions.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\dotnet\DotnetToolsProvider.Install-Version.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\dotnet\DotnetToolsProvider.Uninstall-Version.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\dotnet\Get-DotnetToolsProvider.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\reconciler\Get-Providers.ps1"

    function New-PlainVm {
        [PSCustomObject]@{
            vmName                    = 'node-01'
            _jdkTarballPath           = 'C:\cache\jdk.tar.gz'
            _jdkResolvedVersion       = '21.0.6+7'
            _dotnetSdkTarballPath     = 'C:\cache\dotnet.tar.gz'
            _dotnetSdkResolvedVersion = '10.0.100'
            _dotnetToolNupkgPaths     = @{}
        }
    }
}

Describe 'Get-Providers' {

    It 'registers JDK, dotnet SDK, then dotnet tools (declaration order)' {
        # Dispatch order is a contract: JDK was the first reconciler-owned
        # toolchain and existing manifests assume that order. New providers
        # append after; reordering would change diagnostic log ordering and
        # any future provider-precedence semantics. dotnetTools is nested
        # (ParentProvider = 'dotnetSdk'), so the top-level loop will skip
        # it - but Get-Providers still surfaces it so the reconciler's
        # by-Name lookup for the children walker is populated.
        $providers = @(Get-Providers -Vm (New-PlainVm))

        $providers.Count   | Should -Be 3
        $providers[0].Name | Should -Be 'javaDevKit'
        $providers[1].Name | Should -Be 'dotnetSdk'
        $providers[2].Name | Should -Be 'dotnetTools'
    }

    It 'marks dotnetTools as nested under dotnetSdk' {
        # The children walker keys off ParentProvider to partition
        # nested providers out of the main dispatch loop. A regression
        # that drops this field would cause dotnetTools to run twice
        # (top-level AND via the walker) on parent uninstall.
        $providers = @(Get-Providers -Vm (New-PlainVm))
        $tools     = $providers | Where-Object { $_.Name -eq 'dotnetTools' }
        $tools.ParentProvider | Should -Be 'dotnetSdk'
    }

    It 'returns providers that pass Assert-ToolchainProvider' {
        # Shape check: each provider must carry the four scriptblock
        # members the orchestrator dispatches against. Catching a
        # malformed provider here means a regression in Get-JdkProvider
        # or Get-DotnetSdkProvider fails this test rather than crashing
        # inside the reconciler mid-dispatch on a real VM.
        $providers = @(Get-Providers -Vm (New-PlainVm))
        foreach ($p in $providers) {
            { Assert-ToolchainProvider -Provider $p } | Should -Not -Throw
        }
    }

    It 'returns a value the caller can foreach over without a null guard' {
        # Regression guard: the implementation uses `@(...)` precisely
        # so the result surfaces as an enumerable rather than getting
        # unwrapped to a scalar when only one provider is registered.
        $count = 0
        foreach ($p in (Get-Providers -Vm (New-PlainVm))) { $count++ }
        $count | Should -Be 3
    }
}
