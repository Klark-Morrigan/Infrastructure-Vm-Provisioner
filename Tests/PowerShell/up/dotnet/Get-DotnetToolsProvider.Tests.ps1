BeforeAll {
    # Provider-Contract.ps1 supplies Assert-ToolchainProvider; the four
    # DotnetToolsProvider.* operation files supply the helpers
    # Get-DotnetToolsProvider captures into closures.
    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\up\reconciler\Provider-Contract.ps1"
    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\up\dotnet\DotnetToolsProvider.Get-DesiredVersions.ps1"
    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\up\dotnet\DotnetToolsProvider.Get-InstalledVersions.ps1"
    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\up\dotnet\DotnetToolsProvider.Install-Version.ps1"
    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\up\dotnet\DotnetToolsProvider.Uninstall-Version.ps1"
    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\up\dotnet\Get-DotnetToolsProvider.ps1"

    function New-PlainVm {
        [PSCustomObject]@{
            vmName                 = 'node-01'
            _dotnetToolNupkgPaths  = @{ 'reportgenerator@5.4.4' = 'C:\cache\reportgenerator.5.4.4.nupkg' }
        }
    }
}

Describe 'Get-DotnetToolsProvider' {

    It 'returns a provider named "dotnetTools"' {
        # Name is the JSON field this provider consumes - the reconciler
        # uses it to log per-provider failures and to scope manifests
        # via Get-VmManifestsByProvider.
        $provider = Get-DotnetToolsProvider -Vm (New-PlainVm)
        $provider.Name | Should -Be 'dotnetTools'
    }

    It 'carries ParentProvider = "dotnetSdk" (nested-provider marker)' {
        # The orchestrator partitions providers on this field; without
        # it the tools provider would run in the top-level loop and the
        # children walker would not be exercised. Without the right
        # parent name, the SDK provider's children array entries would
        # not resolve to this provider at uninstall time.
        $provider = Get-DotnetToolsProvider -Vm (New-PlainVm)
        $provider.ParentProvider | Should -Be 'dotnetSdk'
    }

    It 'passes Assert-ToolchainProvider' {
        # Shape check: all four scriptblock members are present and of
        # the correct type. A regression in the composition would fail
        # this test before the reconciler dispatches against the
        # malformed object on a real VM.
        $provider = Get-DotnetToolsProvider -Vm (New-PlainVm)
        { Assert-ToolchainProvider -Provider $provider } | Should -Not -Throw
    }
}
