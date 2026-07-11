BeforeAll {
    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\up\dotnet\DotnetSdkProvider.Get-DesiredVersions.ps1"

    # ConvertFrom-Json is used to build $VmConfig inputs so the test
    # shapes match exactly what the production code sees at runtime
    # (PSCustomObject for JSON objects, object[] for JSON arrays). Hand-
    # built hashtables would diverge from the real type surface and
    # could mask -is [PSCustomObject] regressions.
    function New-VmConfigFromJson {
        param(
            [Parameter(Mandatory)] [string] $Json,
            # Most tests need the acquisition-stamped fields. Pass $null
            # to either to omit it (used by the "throws when acquisition
            # did not run" cases).
            [string] $ResolvedVersion = '10.0.100',
            [string] $TarballPath     = 'C:\cache\dotnet-sdk-10.0.100-linux-x64.tar.gz'
        )
        $vm = $Json | ConvertFrom-Json
        if ($null -ne $ResolvedVersion) {
            $vm | Add-Member -NotePropertyName _dotnetSdkResolvedVersion `
                             -NotePropertyValue $ResolvedVersion -Force
        }
        if ($null -ne $TarballPath) {
            $vm | Add-Member -NotePropertyName _dotnetSdkTarballPath `
                             -NotePropertyValue $TarballPath -Force
        }
        return $vm
    }
}

Describe 'Get-DotnetSdkDesiredVersions' {

    # ----------------------------------------------------------------------
    Context 'field absent' {
    # ----------------------------------------------------------------------

        It 'returns $null so the orchestrator skips the provider' {
            $vm = New-VmConfigFromJson '{ "vmName": "x" }'
            $result = Get-DotnetSdkDesiredVersions -VmConfig $vm
            $result | Should -BeNullOrEmpty
            # Distinguish "$null" (skip) from "@()" (ensure-none): only
            # the latter satisfies -is [array].
            ($null -eq $result) | Should -BeTrue
        }
    }

    # ----------------------------------------------------------------------
    Context 'ensure-none signals' {
    # ----------------------------------------------------------------------

        It 'returns @() for explicit null' {
            $vm = New-VmConfigFromJson '{ "dotnetSdk": null }'
            $result = Get-DotnetSdkDesiredVersions -VmConfig $vm
            # Wrap before .Count: a $null pipeline yields a scalar under
            # strict mode.
            ,$result -is [array] | Should -BeTrue
            @($result).Count   | Should -Be 0
        }

        It 'survives the call-operator invocation path without unrolling to $null' {
            # The reconciler invokes provider operations through closures
            # (see Get-DotnetSdkProvider.ps1's scriptblock wrappers). In
            # that path, a bare `return @()` collapses to $null on the
            # way back out, which the reconciler then misreads as "skip
            # this provider" instead of "ensure none installed".
            $vm = New-VmConfigFromJson '{ "dotnetSdk": null }'
            $wrapper = { param($v) Get-DotnetSdkDesiredVersions -VmConfig $v }
            $result  = & $wrapper $vm
            ($null -eq $result)   | Should -BeFalse -Because 'closure return must not unroll to $null'
            ($result -is [array]) | Should -BeTrue
            @($result).Count      | Should -Be 0
        }

        It 'returns @() for explicit empty list' {
            $vm = New-VmConfigFromJson '{ "dotnetSdk": [] }'
            $result = Get-DotnetSdkDesiredVersions -VmConfig $vm
            ,$result -is [array] | Should -BeTrue
            @($result).Count   | Should -Be 0
        }
    }

    # ----------------------------------------------------------------------
    Context 'scalar shape' {
    # ----------------------------------------------------------------------

        It 'wraps a scalar object into a one-element Spec array with the resolved version' {
            $vm = New-VmConfigFromJson `
                -ResolvedVersion '10.0.100' `
                -TarballPath     'C:\cache\dotnet-sdk-10.0.100-linux-x64.tar.gz' `
                -Json @'
{ "dotnetSdk": { "channel": "10.0", "version": "10.0" } }
'@
            $result = Get-DotnetSdkDesiredVersions -VmConfig $vm

            @($result).Count            | Should -Be 1
            $result[0].Provider         | Should -Be 'dotnetSdk'
            $result[0].Channel          | Should -Be '10.0'
            # Version is the RESOLVED form so the reconciler diff matches
            # the manifest's stored version on no-op reruns.
            $result[0].Version          | Should -Be '10.0.100'
            # RequestedVersion preserves the operator's literal pin for
            # diagnostic / display purposes; not used by the diff.
            $result[0].RequestedVersion | Should -Be '10.0'
            $result[0].TarballPath      | Should -Be 'C:\cache\dotnet-sdk-10.0.100-linux-x64.tar.gz'
        }
    }

    # ----------------------------------------------------------------------
    Context 'list shape' {
    # ----------------------------------------------------------------------

        It 'accepts a list of one entry and returns it as a Spec array with the resolved version' {
            $vm = New-VmConfigFromJson `
                -ResolvedVersion '10.0.100' `
                -Json @'
{ "dotnetSdk": [ { "channel": "10.0", "version": "10" } ] }
'@
            $result = Get-DotnetSdkDesiredVersions -VmConfig $vm

            @($result).Count            | Should -Be 1
            $result[0].Provider         | Should -Be 'dotnetSdk'
            $result[0].Channel          | Should -Be '10.0'
            $result[0].Version          | Should -Be '10.0.100'
            $result[0].RequestedVersion | Should -Be '10'
        }

        It 'throws naming the missing _dotnetSdkResolvedVersion field' {
            # Acquisition did not run for this VM. Returning the literal
            # operator request as Spec.Version would force a phantom
            # reinstall on every run, so throw loud instead.
            $vm = New-VmConfigFromJson -ResolvedVersion $null -Json @'
{ "dotnetSdk": { "channel": "10.0", "version": "10.0" } }
'@
            { Get-DotnetSdkDesiredVersions -VmConfig $vm } |
                Should -Throw -ExpectedMessage '*_dotnetSdkResolvedVersion*Invoke-DotnetSdkAcquisition*'
        }

        It 'throws naming the missing _dotnetSdkTarballPath field' {
            $vm = New-VmConfigFromJson -TarballPath $null -Json @'
{ "dotnetSdk": { "channel": "10.0", "version": "10.0" } }
'@
            { Get-DotnetSdkDesiredVersions -VmConfig $vm } |
                Should -Throw -ExpectedMessage '*_dotnetSdkTarballPath*Invoke-DotnetSdkAcquisition*'
        }

        It 'throws naming the observed count for a list of two' {
            $vm = New-VmConfigFromJson @'
{
  "dotnetSdk": [
    { "channel": "10.0", "version": "10.0.100" },
    { "channel": "9.0",  "version": "9.0.100"  }
  ]
}
'@
            { Get-DotnetSdkDesiredVersions -VmConfig $vm } |
                Should -Throw -ExpectedMessage "*one SDK per VM*2*"
        }
    }
}
