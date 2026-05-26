BeforeAll {
    # Provider-Contract.ps1 supplies Assert-ToolchainProvider; the four
    # DotnetSdkProvider.* operation files supply the helpers Get-DotnetSdkProvider
    # captures into closures.
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\reconciler\Provider-Contract.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\dotnet\DotnetSdkProvider.Get-DesiredVersions.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\dotnet\DotnetSdkProvider.Get-InstalledVersions.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\dotnet\DotnetSdkProvider.Install-Version.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\dotnet\DotnetSdkProvider.Uninstall-Version.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\dotnet\Get-DotnetSdkProvider.ps1"

    function New-PlainVm {
        [PSCustomObject]@{
            vmName                    = 'node-01'
            _dotnetSdkTarballPath     = 'C:\cache\dotnet.tar.gz'
            _dotnetSdkResolvedVersion = '10.0.100'
        }
    }
}

Describe 'Get-DotnetSdkProvider' {

    It 'returns a provider named "dotnetSdk"' {
        # Name is the JSON field this provider consumes - the reconciler
        # uses it to log per-provider failures and to scope manifests
        # via Get-VmManifestsByProvider.
        $provider = Get-DotnetSdkProvider -Vm (New-PlainVm)
        $provider.Name | Should -Be 'dotnetSdk'
    }

    It 'passes Assert-ToolchainProvider' {
        # Shape check: all four scriptblock members are present and of
        # the correct type. A regression in the composition would fail
        # this test before the reconciler dispatches against the
        # malformed object on a real VM.
        $provider = Get-DotnetSdkProvider -Vm (New-PlainVm)
        { Assert-ToolchainProvider -Provider $provider } | Should -Not -Throw
    }
}
