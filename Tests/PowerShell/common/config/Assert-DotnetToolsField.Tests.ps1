BeforeAll {
    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\common\config\Assert-DotnetToolsField.ps1"

    # Builds a VM definition with the given JSON fragments as its
    # 'dotnetTools' and (optionally) 'dotnetSdk' fields. Tests parse JSON
    # rather than constructing PSCustomObjects by hand so the validator
    # sees the same shape ConvertFrom-VmConfigJson hands it at runtime.
    function New-VmJson {
        param(
            [AllowNull()] [object] $ToolsJson,
            [AllowNull()] [object] $SdkJson = '{ "channel": "10.0", "version": "10.0.100" }'
        )
        $parts = @('"vmName": "node-01"')
        if ($null -ne $SdkJson)   { $parts += "`"dotnetSdk`": $SdkJson" }
        if ($null -ne $ToolsJson) { $parts += "`"dotnetTools`": $ToolsJson" }
        return ('{ ' + ($parts -join ', ') + ' }' | ConvertFrom-Json)
    }
}

Describe 'Assert-DotnetToolsField' {

    # ------------------------------------------------------------------
    Context 'optional field absent / ensure-none signals' {
    # ------------------------------------------------------------------

        It 'returns silently when dotnetTools is absent' {
            $vm = New-VmJson -ToolsJson $null
            { Assert-DotnetToolsField -Vm $vm } | Should -Not -Throw
        }

        It 'returns silently for explicit null' {
            $vm = New-VmJson 'null'
            { Assert-DotnetToolsField -Vm $vm } | Should -Not -Throw
        }

        It 'returns silently for explicit empty array' {
            $vm = New-VmJson '[]'
            { Assert-DotnetToolsField -Vm $vm } | Should -Not -Throw
        }

        It 'passes when dotnetTools is empty and dotnetSdk is also absent (ensure-none on both)' {
            $vm = New-VmJson -ToolsJson '[]' -SdkJson $null
            { Assert-DotnetToolsField -Vm $vm } | Should -Not -Throw
        }
    }

    # ------------------------------------------------------------------
    Context 'valid entries' {
    # ------------------------------------------------------------------

        It 'accepts a single valid entry' {
            $vm = New-VmJson '[ { "id": "dotnet-reportgenerator-globaltool", "version": "5.4.4" } ]'
            { Assert-DotnetToolsField -Vm $vm } | Should -Not -Throw
        }

        It 'accepts two valid entries and preserves ordering' {
            $vm = New-VmJson @'
[
  { "id": "dotnet-reportgenerator-globaltool", "version": "5.4.4" },
  { "id": "dotnet-ef",                          "version": "8.0.0" }
]
'@
            { Assert-DotnetToolsField -Vm $vm } | Should -Not -Throw
            $vm.dotnetTools[0].id | Should -Be 'dotnet-reportgenerator-globaltool'
            $vm.dotnetTools[1].id | Should -Be 'dotnet-ef'
        }
    }

    # ------------------------------------------------------------------
    Context 'shape validation' {
    # ------------------------------------------------------------------

        It 'throws when dotnetTools is a scalar object (must be an array)' {
            $vm = New-VmJson '{ "id": "x", "version": "1.0.0" }'
            { Assert-DotnetToolsField -Vm $vm } |
                Should -Throw -ExpectedMessage "*dotnetTools*array*"
        }

        It 'throws when dotnetTools is a string' {
            $vm = New-VmJson '"x"'
            { Assert-DotnetToolsField -Vm $vm } |
                Should -Throw -ExpectedMessage "*dotnetTools*array*"
        }

        It 'throws when an entry is not an object' {
            $vm = New-VmJson '[ "x" ]'
            { Assert-DotnetToolsField -Vm $vm } |
                Should -Throw -ExpectedMessage "*entry*object*"
        }
    }

    # ------------------------------------------------------------------
    Context 'id validation' {
    # ------------------------------------------------------------------

        It 'throws when id is missing' {
            $vm = New-VmJson '[ { "version": "5.4.4" } ]'
            { Assert-DotnetToolsField -Vm $vm } |
                Should -Throw -ExpectedMessage "*id*"
        }

        It 'throws when id is empty' {
            $vm = New-VmJson '[ { "id": "", "version": "5.4.4" } ]'
            { Assert-DotnetToolsField -Vm $vm } |
                Should -Throw -ExpectedMessage "*id*"
        }

        It 'throws when id is not a string' {
            $vm = New-VmJson '[ { "id": 5, "version": "5.4.4" } ]'
            { Assert-DotnetToolsField -Vm $vm } |
                Should -Throw -ExpectedMessage "*id*string*"
        }

        It 'throws when id violates the NuGet id grammar (contains slash)' {
            $vm = New-VmJson '[ { "id": "bad/id", "version": "5.4.4" } ]'
            { Assert-DotnetToolsField -Vm $vm } |
                Should -Throw -ExpectedMessage "*id*bad/id*"
        }

        It 'throws when id contains whitespace' {
            $vm = New-VmJson '[ { "id": "bad id", "version": "5.4.4" } ]'
            { Assert-DotnetToolsField -Vm $vm } |
                Should -Throw -ExpectedMessage "*id*"
        }
    }

    # ------------------------------------------------------------------
    Context 'version validation' {
    # ------------------------------------------------------------------

        It 'throws when version is missing' {
            $vm = New-VmJson '[ { "id": "dotnet-ef" } ]'
            { Assert-DotnetToolsField -Vm $vm } |
                Should -Throw -ExpectedMessage "*version*"
        }

        It 'throws when version is empty' {
            $vm = New-VmJson '[ { "id": "dotnet-ef", "version": "" } ]'
            { Assert-DotnetToolsField -Vm $vm } |
                Should -Throw -ExpectedMessage "*version*"
        }

        It 'throws when version is not a string' {
            $vm = New-VmJson '[ { "id": "dotnet-ef", "version": 5 } ]'
            { Assert-DotnetToolsField -Vm $vm } |
                Should -Throw -ExpectedMessage "*version*string*"
        }

        It 'throws when version contains whitespace' {
            $vm = New-VmJson '[ { "id": "dotnet-ef", "version": "1.0 .0" } ]'
            { Assert-DotnetToolsField -Vm $vm } |
                Should -Throw -ExpectedMessage "*version*"
        }

        It 'throws when version is "latest"' {
            $vm = New-VmJson '[ { "id": "dotnet-ef", "version": "latest" } ]'
            { Assert-DotnetToolsField -Vm $vm } |
                Should -Throw -ExpectedMessage "*version*latest*"
        }

        It 'throws when version is a floating range' {
            $vm = New-VmJson '[ { "id": "dotnet-ef", "version": "[1.0,2.0)" } ]'
            { Assert-DotnetToolsField -Vm $vm } |
                Should -Throw -ExpectedMessage "*version*"
        }
    }

    # ------------------------------------------------------------------
    Context 'strict sub-field set' {
    # ------------------------------------------------------------------

        It 'throws when an unknown sub-field is present (typo guard)' {
            $vm = New-VmJson '[ { "id": "dotnet-ef", "version": "8.0.0", "versoin": "x" } ]'
            { Assert-DotnetToolsField -Vm $vm } |
                Should -Throw -ExpectedMessage "*versoin*"
        }
    }

    # ------------------------------------------------------------------
    Context 'cross-field: dotnetTools requires dotnetSdk' {
    # ------------------------------------------------------------------

        It 'throws when dotnetTools is non-empty and dotnetSdk is absent' {
            $vm = New-VmJson -ToolsJson '[ { "id": "dotnet-ef", "version": "8.0.0" } ]' -SdkJson $null
            { Assert-DotnetToolsField -Vm $vm } |
                Should -Throw -ExpectedMessage "*dotnetTools*dotnetSdk*"
        }

        It 'throws when dotnetTools is non-empty and dotnetSdk is null' {
            $vm = New-VmJson -ToolsJson '[ { "id": "dotnet-ef", "version": "8.0.0" } ]' -SdkJson 'null'
            { Assert-DotnetToolsField -Vm $vm } |
                Should -Throw -ExpectedMessage "*dotnetTools*dotnetSdk*"
        }

        It 'throws when dotnetTools is non-empty and dotnetSdk is empty array' {
            $vm = New-VmJson -ToolsJson '[ { "id": "dotnet-ef", "version": "8.0.0" } ]' -SdkJson '[]'
            { Assert-DotnetToolsField -Vm $vm } |
                Should -Throw -ExpectedMessage "*dotnetTools*dotnetSdk*"
        }
    }

    # ------------------------------------------------------------------
    Context 'error message contains VM context' {
    # ------------------------------------------------------------------

        It 'includes the vmName in the thrown message' {
            $vm = New-VmJson '[ { "id": "", "version": "5.4.4" } ]'
            { Assert-DotnetToolsField -Vm $vm } |
                Should -Throw -ExpectedMessage "*node-01*"
        }

        It 'falls back to (unknown) when vmName is absent' {
            $json = '{ "dotnetSdk": { "channel": "10.0", "version": "10.0.100" }, "dotnetTools": [ { "id": "", "version": "5.4.4" } ] }'
            $vm   = ($json | ConvertFrom-Json)
            { Assert-DotnetToolsField -Vm $vm } |
                Should -Throw -ExpectedMessage "*(unknown)*"
        }
    }
}
