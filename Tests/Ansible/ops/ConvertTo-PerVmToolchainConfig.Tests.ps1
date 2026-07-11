BeforeAll {
    # The SUT defines pure functions with no top-level side effects, so a plain
    # dot-source is safe with no module import or mock seam.
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\Ansible\ops\ConvertTo-PerVmToolchainConfig.ps1"

    function New-Vm {
        param([string] $Name = 'vm', [hashtable] $Fields = @{})
        $base = @{ vmName = $Name; kind = 'workload' }
        foreach ($k in $Fields.Keys) { $base[$k] = $Fields[$k] }
        [pscustomobject]$base
    }
    function New-Jdk  { param($v) [pscustomobject]@{ vendor = 'temurin'; version = $v } }
    function New-Sdk  { param($c, $v) [pscustomobject]@{ channel = $c; version = $v } }
    function New-Tool { param($id, $v) [pscustomobject]@{ id = $id; version = $v } }

    # Property names of a per-host map (the emitted vmNames). Pipe the property
    # collection rather than member-enumerating .Name, which throws under
    # StrictMode on an empty object.
    function Get-HostNames { param($Map) @($Map.PSObject.Properties | ForEach-Object { $_.Name }) }
}

Describe 'ConvertTo-PerVmToolchainConfig' {

    Context 'empty and absent inputs' {
        It 'ConvertToPerVmToolchainConfig_ReturnsEmptyMap_ForEmptyFleet' {
            $result = ConvertTo-PerVmToolchainConfig -VmConfigs @()
            @(Get-HostNames $result).Count | Should -Be 0
        }

        It 'ConvertToPerVmToolchainConfig_OmitsVmsWithNoToolchains' {
            $result = ConvertTo-PerVmToolchainConfig -VmConfigs @((New-Vm -Name 'a'))
            @(Get-HostNames $result).Count | Should -Be 0
        }

        It 'ConvertToPerVmToolchainConfig_TreatsNullAndEmptyAsNoToolchains' {
            $vm = New-Vm -Name 'a' -Fields @{ javaDevKit = $null; dotnetSdk = @(); dotnetTools = @() }
            $result = ConvertTo-PerVmToolchainConfig -VmConfigs @($vm)
            @(Get-HostNames $result).Count | Should -Be 0
        }
    }

    Context 'per-VM projection (NOT a union)' {
        It 'ConvertToPerVmToolchainConfig_KeysByVmName_WithEachHostsOwnPins' {
            $vms = @(
                (New-Vm -Name 'ubuntu-01' -Fields @{ javaDevKit = (New-Jdk '21') }),
                (New-Vm -Name 'ubuntu-02' -Fields @{ javaDevKit = (New-Jdk '17') })
            )
            $result = ConvertTo-PerVmToolchainConfig -VmConfigs $vms

            Get-HostNames $result | Should -Be @('ubuntu-01', 'ubuntu-02')
            # Crucially each host gets ONLY its own JDK - no union.
            $result.'ubuntu-01'.jdk_versions | Should -Be @('21')
            $result.'ubuntu-02'.jdk_versions | Should -Be @('17')
        }

        It 'ConvertToPerVmToolchainConfig_DropsVendorFromJdk' {
            $result = ConvertTo-PerVmToolchainConfig -VmConfigs @(
                (New-Vm -Name 'a' -Fields @{ javaDevKit = (New-Jdk '21') }))
            $result.'a'.jdk_versions | Should -Be @('21')
        }

        It 'ConvertToPerVmToolchainConfig_NormalizesScalarAndOneListIdentically' {
            $scalar = New-Vm -Name 'a' -Fields @{ javaDevKit = (New-Jdk '21') }
            $list   = New-Vm -Name 'b' -Fields @{ javaDevKit = @((New-Jdk '21')) }
            $r = ConvertTo-PerVmToolchainConfig -VmConfigs @($scalar, $list)
            $r.'a'.jdk_versions | Should -Be $r.'b'.jdk_versions
        }

        It 'ConvertToPerVmToolchainConfig_PassesSdkAndToolShapesVerbatim' {
            $vm = New-Vm -Name 'a' -Fields @{
                dotnetSdk   = (New-Sdk '10.0' '10.0.100')
                dotnetTools = @((New-Tool 'dotnet-format' '5.1.0'))
            }
            $result = ConvertTo-PerVmToolchainConfig -VmConfigs @($vm)
            $result.'a'.dotnet_sdk_versions[0].channel | Should -Be '10.0'
            $result.'a'.dotnet_sdk_versions[0].version | Should -Be '10.0.100'
            $result.'a'.dotnet_tools_tools[0].id       | Should -Be 'dotnet-format'
        }

        It 'ConvertToPerVmToolchainConfig_DedupesRepeatedPinsWithinAVm' {
            $vm = New-Vm -Name 'a' -Fields @{
                dotnetTools = @((New-Tool 'dotnet-format' '5.1.0'),
                                (New-Tool 'dotnet-format' '5.1.0'))
            }
            $result = ConvertTo-PerVmToolchainConfig -VmConfigs @($vm)
            @($result.'a'.dotnet_tools_tools).Count | Should -Be 1
        }

        It 'ConvertToPerVmToolchainConfig_DoesNotBleedToolchainsBetweenHosts' {
            # A host with only an SDK must NOT pick up another host's tools.
            $vms = @(
                (New-Vm -Name 'sdk-only'  -Fields @{ dotnetSdk = (New-Sdk '10.0' '10.0.100') }),
                (New-Vm -Name 'tool-only' -Fields @{ dotnetTools = @((New-Tool 'dotnet-format' '5.1.0')) })
            )
            $result = ConvertTo-PerVmToolchainConfig -VmConfigs $vms
            @($result.'sdk-only'.dotnet_tools_tools).Count  | Should -Be 0
            @($result.'tool-only'.dotnet_sdk_versions).Count | Should -Be 0
        }
    }

    Context 'router exclusion' {
        It 'ConvertToPerVmToolchainConfig_SkipsRouterVms' {
            $router = New-Vm -Name 'router' -Fields @{ kind = 'router'; javaDevKit = (New-Jdk '21') }
            $result = ConvertTo-PerVmToolchainConfig -VmConfigs @($router)
            @(Get-HostNames $result).Count | Should -Be 0
        }
    }
}
