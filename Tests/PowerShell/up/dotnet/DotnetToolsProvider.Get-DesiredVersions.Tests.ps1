BeforeAll {
    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\up\dotnet\DotnetToolsProvider.Get-DesiredVersions.ps1"

    # ConvertFrom-Json builds inputs whose type surface matches what the
    # production code sees at runtime (PSCustomObject for JSON objects,
    # object[] for JSON arrays). Hand-built hashtables would diverge.
    function New-VmConfigFromJson {
        param(
            [Parameter(Mandatory)] [string] $Json,
            [hashtable] $NupkgPaths
        )
        $vm = $Json | ConvertFrom-Json
        if ($null -ne $NupkgPaths) {
            $vm | Add-Member -NotePropertyName _dotnetToolNupkgPaths `
                             -NotePropertyValue $NupkgPaths -Force
        }
        return $vm
    }
}

Describe 'Get-DotnetToolsDesiredVersions' {

    # ----------------------------------------------------------------------
    Context 'field absent' {
    # ----------------------------------------------------------------------

        It 'returns $null so the orchestrator skips the provider' {
            $vm = New-VmConfigFromJson '{ "vmName": "x" }'
            $result = Get-DotnetToolsDesiredVersions -VmConfig $vm
            # Distinguish "$null" (skip) from "@()" (ensure-none).
            ($null -eq $result) | Should -BeTrue
        }
    }

    # ----------------------------------------------------------------------
    Context 'ensure-none signals' {
    # ----------------------------------------------------------------------

        It 'returns @() for explicit null' {
            $vm = New-VmConfigFromJson '{ "dotnetTools": null }'
            $result = Get-DotnetToolsDesiredVersions -VmConfig $vm
            ,$result -is [array] | Should -BeTrue
            @($result).Count     | Should -Be 0
        }

        It 'survives the call-operator path without unrolling to $null' {
            # The closure wrapper in Get-DotnetToolsProvider invokes us
            # via the call operator; a bare `return @()` would collapse
            # to $null there and the reconciler would misread it as
            # "skip provider" instead of "ensure none installed".
            $vm = New-VmConfigFromJson '{ "dotnetTools": null }'
            $wrapper = { param($v) Get-DotnetToolsDesiredVersions -VmConfig $v }
            $result  = & $wrapper $vm
            ($null -eq $result)   | Should -BeFalse -Because 'closure return must not unroll to $null'
            ($result -is [array]) | Should -BeTrue
            @($result).Count      | Should -Be 0
        }

        It 'returns @() for explicit empty list' {
            $vm = New-VmConfigFromJson '{ "dotnetTools": [] }'
            $result = Get-DotnetToolsDesiredVersions -VmConfig $vm
            ,$result -is [array] | Should -BeTrue
            @($result).Count     | Should -Be 0
        }
    }

    # ----------------------------------------------------------------------
    Context 'happy path' {
    # ----------------------------------------------------------------------

        It 'maps one entry to one Spec carrying composite Version, Id, RawVersion, NupkgPath' {
            $paths = @{
                'dotnet-reportgenerator-globaltool@5.4.4' =
                    'C:\cache\dotnet-tool-dotnet-reportgenerator-globaltool-5.4.4.nupkg'
            }
            $vm = New-VmConfigFromJson -NupkgPaths $paths -Json @'
{
  "dotnetTools": [
    { "id": "dotnet-reportgenerator-globaltool", "version": "5.4.4" }
  ]
}
'@
            $result = Get-DotnetToolsDesiredVersions -VmConfig $vm

            @($result).Count          | Should -Be 1
            $result[0].Provider       | Should -Be 'dotnetTools'
            $result[0].Version        | Should -Be 'dotnet-reportgenerator-globaltool@5.4.4'
            $result[0].Id             | Should -Be 'dotnet-reportgenerator-globaltool'
            $result[0].RawVersion     | Should -Be '5.4.4'
            $result[0].NupkgPath      | Should -Be 'C:\cache\dotnet-tool-dotnet-reportgenerator-globaltool-5.4.4.nupkg'
        }

        It 'preserves declaration order across multiple entries' {
            $paths = @{
                'a@1.0.0' = 'C:\cache\dotnet-tool-a-1.0.0.nupkg'
                'b@2.0.0' = 'C:\cache\dotnet-tool-b-2.0.0.nupkg'
            }
            $vm = New-VmConfigFromJson -NupkgPaths $paths -Json @'
{
  "dotnetTools": [
    { "id": "a", "version": "1.0.0" },
    { "id": "b", "version": "2.0.0" }
  ]
}
'@
            $result = Get-DotnetToolsDesiredVersions -VmConfig $vm

            @($result).Count   | Should -Be 2
            $result[0].Id      | Should -Be 'a'
            $result[1].Id      | Should -Be 'b'
        }
    }

    # ----------------------------------------------------------------------
    Context 'acquisition stamp missing' {
    # ----------------------------------------------------------------------

        It 'throws naming _dotnetToolNupkgPaths when entries are non-empty and stamp is absent' {
            # Acquisition did not run; Install-Version would otherwise
            # explode with a less-actionable error deep in the SSH path.
            $vm = New-VmConfigFromJson -NupkgPaths $null -Json @'
{ "dotnetTools": [ { "id": "x", "version": "1.0.0" } ] }
'@
            { Get-DotnetToolsDesiredVersions -VmConfig $vm } |
                Should -Throw -ExpectedMessage '*_dotnetToolNupkgPaths*Invoke-DotnetToolAcquisition*'
        }

        It 'throws naming the missing key when one entry has no cached nupkg' {
            $paths = @{ 'a@1.0.0' = 'C:\cache\a.nupkg' }
            $vm = New-VmConfigFromJson -NupkgPaths $paths -Json @'
{
  "dotnetTools": [
    { "id": "a", "version": "1.0.0" },
    { "id": "b", "version": "2.0.0" }
  ]
}
'@
            { Get-DotnetToolsDesiredVersions -VmConfig $vm } |
                Should -Throw -ExpectedMessage '*b@2.0.0*_dotnetToolNupkgPaths*'
        }
    }
}
