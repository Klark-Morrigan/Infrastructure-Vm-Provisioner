BeforeAll {
    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\common\config\Assert-DotnetSdkField.ps1"

    # Builds a VM definition object with the given JSON fragment as its
    # 'dotnetSdk' field. Tests parse JSON rather than constructing
    # PSCustomObjects by hand so the validator sees the same shape that
    # ConvertFrom-VmConfigJson hands it at runtime.
    function New-VmWithSdkJson([string] $SdkJson) {
        $json = if ($null -eq $SdkJson) {
            '{ "vmName": "node-01" }'
        } else {
            "{ `"vmName`": `"node-01`", `"dotnetSdk`": $SdkJson }"
        }
        return ($json | ConvertFrom-Json)
    }

    function New-VmWithoutSdk {
        return ('{ "vmName": "node-01" }' | ConvertFrom-Json)
    }
}

Describe 'Assert-DotnetSdkField' {

    # ------------------------------------------------------------------
    Context 'optional field absent' {
    # ------------------------------------------------------------------

        It 'returns silently when dotnetSdk is absent' {
            $vm = New-VmWithoutSdk
            { Assert-DotnetSdkField -Vm $vm } | Should -Not -Throw
        }

        It 'does not add a dotnetSdk field when absent' {
            $vm = New-VmWithoutSdk
            Assert-DotnetSdkField -Vm $vm
            $vm.PSObject.Properties['dotnetSdk'] | Should -BeNullOrEmpty
        }
    }

    # ------------------------------------------------------------------
    Context 'ensure-none signals' {
    # ------------------------------------------------------------------

        It 'returns silently for explicit null (reconciler "ensure none")' {
            $vm = New-VmWithSdkJson 'null'
            { Assert-DotnetSdkField -Vm $vm } | Should -Not -Throw
        }

        It 'returns silently for explicit empty list (reconciler "ensure none")' {
            $vm = New-VmWithSdkJson '[]'
            { Assert-DotnetSdkField -Vm $vm } | Should -Not -Throw
        }
    }

    # ------------------------------------------------------------------
    Context 'valid dotnetSdk - scalar shape' {
    # ------------------------------------------------------------------

        It 'accepts channel "10.0" with major-only version "10"' {
            $vm = New-VmWithSdkJson '{ "channel": "10.0", "version": "10" }'
            { Assert-DotnetSdkField -Vm $vm } | Should -Not -Throw
        }

        It 'accepts major.minor version "10.0"' {
            $vm = New-VmWithSdkJson '{ "channel": "10.0", "version": "10.0" }'
            { Assert-DotnetSdkField -Vm $vm } | Should -Not -Throw
        }

        It 'accepts major.minor.patch version "10.0.100"' {
            $vm = New-VmWithSdkJson '{ "channel": "10.0", "version": "10.0.100" }'
            { Assert-DotnetSdkField -Vm $vm } | Should -Not -Throw
        }
    }

    # ------------------------------------------------------------------
    Context 'valid dotnetSdk - list shape' {
    # ------------------------------------------------------------------

        It 'accepts a list of one entry' {
            $vm = New-VmWithSdkJson '[ { "channel": "10.0", "version": "10.0.100" } ]'
            { Assert-DotnetSdkField -Vm $vm } | Should -Not -Throw
        }

        It 'throws when the list has more than one entry (v1 cap)' {
            $vm = New-VmWithSdkJson @'
[
  { "channel": "10.0", "version": "10.0.100" },
  { "channel": "9.0",  "version": "9.0.100"  }
]
'@
            { Assert-DotnetSdkField -Vm $vm } |
                Should -Throw -ExpectedMessage "*one .NET SDK per VM*"
        }

        It 'applies the same channel/version rules to list entries' {
            $vm = New-VmWithSdkJson '[ { "channel": "10", "version": "10.0.100" } ]'
            { Assert-DotnetSdkField -Vm $vm } |
                Should -Throw -ExpectedMessage "*channel*major*minor*"
        }
    }

    # ------------------------------------------------------------------
    Context 'channel validation' {
    # ------------------------------------------------------------------

        It 'throws when channel is missing' {
            $vm = New-VmWithSdkJson '{ "version": "10.0.100" }'
            { Assert-DotnetSdkField -Vm $vm } |
                Should -Throw -ExpectedMessage "*channel*"
        }

        It 'throws when channel is a JSON number (not a string)' {
            # JSON number 10.0 parses to Int32 (10), dropping the trailing
            # zero - exactly the kind of silent degradation the type guard
            # prevents.
            $vm = New-VmWithSdkJson '{ "channel": 10.0, "version": "10.0.100" }'
            { Assert-DotnetSdkField -Vm $vm } |
                Should -Throw -ExpectedMessage "*channel*string*"
        }

        It 'throws when channel does not match major.minor pattern' {
            $vm = New-VmWithSdkJson '{ "channel": "10", "version": "10.0.100" }'
            { Assert-DotnetSdkField -Vm $vm } |
                Should -Throw -ExpectedMessage "*channel*major*minor*"
        }

        It 'throws when channel has three segments' {
            $vm = New-VmWithSdkJson '{ "channel": "10.0.0", "version": "10.0.100" }'
            { Assert-DotnetSdkField -Vm $vm } |
                Should -Throw -ExpectedMessage "*channel*major*minor*"
        }
    }

    # ------------------------------------------------------------------
    Context 'version validation' {
    # ------------------------------------------------------------------

        It 'throws when version is missing' {
            $vm = New-VmWithSdkJson '{ "channel": "10.0" }'
            { Assert-DotnetSdkField -Vm $vm } |
                Should -Throw -ExpectedMessage "*version*"
        }

        It 'throws when version is a JSON number (not a string)' {
            $vm = New-VmWithSdkJson '{ "channel": "10.0", "version": 10 }'
            { Assert-DotnetSdkField -Vm $vm } |
                Should -Throw -ExpectedMessage "*version*string*"
        }

        It 'throws when version has four numeric segments' {
            $vm = New-VmWithSdkJson '{ "channel": "10.0", "version": "10.0.100.1" }'
            { Assert-DotnetSdkField -Vm $vm } |
                Should -Throw -ExpectedMessage "*version*granularity*"
        }

        It 'throws when version contains a preview tag' {
            $vm = New-VmWithSdkJson '{ "channel": "10.0", "version": "10.0.100-preview" }'
            { Assert-DotnetSdkField -Vm $vm } |
                Should -Throw -ExpectedMessage "*version*granularity*"
        }

        It 'throws when version is an empty string' {
            $vm = New-VmWithSdkJson '{ "channel": "10.0", "version": "" }'
            { Assert-DotnetSdkField -Vm $vm } |
                Should -Throw -ExpectedMessage "*version*granularity*"
        }
    }

    # ------------------------------------------------------------------
    Context 'strict sub-field set' {
    # ------------------------------------------------------------------

        It 'throws when an unknown sub-field is present (typo guard)' {
            $vm = New-VmWithSdkJson '{ "channel": "10.0", "versoin": "10.0.100" }'
            { Assert-DotnetSdkField -Vm $vm } |
                Should -Throw -ExpectedMessage "*versoin*"
        }

        It 'throws when an extra sub-field is present alongside valid ones' {
            $vm = New-VmWithSdkJson '{ "channel": "10.0", "version": "10.0.100", "arch": "x64" }'
            { Assert-DotnetSdkField -Vm $vm } |
                Should -Throw -ExpectedMessage "*arch*"
        }
    }

    # ------------------------------------------------------------------
    Context 'shape validation' {
    # ------------------------------------------------------------------

        It 'throws when dotnetSdk is a string instead of an object/array' {
            $vm = New-VmWithSdkJson '"10.0.100"'
            { Assert-DotnetSdkField -Vm $vm } |
                Should -Throw -ExpectedMessage "*dotnetSdk*object*"
        }
    }

    # ------------------------------------------------------------------
    Context 'error message contains VM context' {
    # ------------------------------------------------------------------

        It 'includes the vmName in the thrown message' {
            $vm = New-VmWithSdkJson '{ "channel": "10", "version": "10.0.100" }'
            { Assert-DotnetSdkField -Vm $vm } |
                Should -Throw -ExpectedMessage "*node-01*"
        }

        It 'falls back to (unknown) when vmName is absent' {
            $json = '{ "dotnetSdk": { "channel": "10", "version": "10.0.100" } }'
            $vm   = ($json | ConvertFrom-Json)
            { Assert-DotnetSdkField -Vm $vm } |
                Should -Throw -ExpectedMessage "*(unknown)*"
        }
    }
}
