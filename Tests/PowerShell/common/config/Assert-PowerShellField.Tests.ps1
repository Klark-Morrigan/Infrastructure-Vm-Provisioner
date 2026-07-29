BeforeAll {
    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\common\config\Assert-PowerShellField.ps1"

    # Builds a VM definition object with the given JSON fragment as its
    # 'powershell' field. Tests parse JSON rather than constructing
    # PSCustomObjects by hand so the validator sees the same shape that
    # ConvertFrom-VmConfigJson hands it at runtime - notably a JSON number
    # arriving as [long]/[double] rather than a string.
    function New-VmWithPowerShellJson([string] $PsJson) {
        $json = if ($null -eq $PsJson) {
            '{ "vmName": "node-01" }'
        } else {
            "{ `"vmName`": `"node-01`", `"powershell`": $PsJson }"
        }
        return ($json | ConvertFrom-Json)
    }

    function New-VmWithoutPowerShell {
        return ('{ "vmName": "node-01" }' | ConvertFrom-Json)
    }
}

Describe 'Assert-PowerShellField' {

    # ------------------------------------------------------------------
    Context 'optional field absent' {
    # ------------------------------------------------------------------

        It 'returns silently when powershell is absent' {
            { Assert-PowerShellField -Vm (New-VmWithoutPowerShell) } | Should -Not -Throw
        }

        It 'does not add a powershell field when absent' {
            $vm = New-VmWithoutPowerShell
            Assert-PowerShellField -Vm $vm
            $vm.PSObject.Properties['powershell'] | Should -BeNullOrEmpty
        }
    }

    # ------------------------------------------------------------------
    Context 'ensure-none signals' {
    # ------------------------------------------------------------------

        It 'returns silently for explicit null' {
            { Assert-PowerShellField -Vm (New-VmWithPowerShellJson 'null') } |
                Should -Not -Throw
        }

        It 'returns silently for an empty list' {
            { Assert-PowerShellField -Vm (New-VmWithPowerShellJson '[]') } |
                Should -Not -Throw
        }
    }

    # ------------------------------------------------------------------
    Context 'accepted shapes' {
    # ------------------------------------------------------------------

        It 'accepts a scalar object' {
            { Assert-PowerShellField -Vm (New-VmWithPowerShellJson '{ "version": "7.6.4" }') } |
                Should -Not -Throw
        }

        It 'accepts a single-entry list' {
            { Assert-PowerShellField -Vm (New-VmWithPowerShellJson '[{ "version": "7.6.4" }]') } |
                Should -Not -Throw
        }

        It 'rejects a shape that is neither object, list, nor null' {
            { Assert-PowerShellField -Vm (New-VmWithPowerShellJson '"7.6.4"') } |
                Should -Throw -ExpectedMessage '*must be a JSON object, an array of objects, or null*'
        }
    }

    # ------------------------------------------------------------------
    Context 'version granularities' {
    # ------------------------------------------------------------------

        # The three the resolver's parse gate accepts. Keeping the two in
        # step is the point: a version this validator passes must be one the
        # staging step can actually resolve.
        It "accepts the major-only granularity" {
            { Assert-PowerShellField -Vm (New-VmWithPowerShellJson '{ "version": "7" }') } |
                Should -Not -Throw
        }

        It "accepts the major.minor granularity" {
            { Assert-PowerShellField -Vm (New-VmWithPowerShellJson '{ "version": "7.6" }') } |
                Should -Not -Throw
        }

        It "accepts the major.minor.patch granularity" {
            { Assert-PowerShellField -Vm (New-VmWithPowerShellJson '{ "version": "7.6.4" }') } |
                Should -Not -Throw
        }

        It 'rejects a four-part version' {
            { Assert-PowerShellField -Vm (New-VmWithPowerShellJson '{ "version": "7.6.4.1" }') } |
                Should -Throw -ExpectedMessage "*not a recognised granularity*'7', '7.6' or '7.6.4'*"
        }

        # Previews are excluded by the resolver, so accepting one here would
        # only defer the failure to staging.
        It 'rejects a prerelease version' {
            $vm = New-VmWithPowerShellJson '{ "version": "7.7.0-preview.3" }'
            { Assert-PowerShellField -Vm $vm } |
                Should -Throw -ExpectedMessage '*not a recognised granularity*'
        }

        It 'rejects a v-prefixed version' {
            { Assert-PowerShellField -Vm (New-VmWithPowerShellJson '{ "version": "v7.6.4" }') } |
                Should -Throw -ExpectedMessage '*not a recognised granularity*'
        }

        It 'rejects a trailing-garbage version' {
            { Assert-PowerShellField -Vm (New-VmWithPowerShellJson '{ "version": "7.6.4foo" }') } |
                Should -Throw -ExpectedMessage '*not a recognised granularity*'
        }
    }

    # ------------------------------------------------------------------
    Context 'version type' {
    # ------------------------------------------------------------------

        # JSON cannot round-trip '7.6' distinctly from '7.60' as a number,
        # and '7.6.4' is not a valid JSON number at all - so string-only is
        # the single consistent rule, and the diagnostic says so.
        It 'rejects a numeric version with a string-only message' {
            { Assert-PowerShellField -Vm (New-VmWithPowerShellJson '{ "version": 7 }') } |
                Should -Throw -ExpectedMessage '*must be a string*Numeric JSON values are not accepted*'
        }

        It 'rejects a fractional numeric version' {
            { Assert-PowerShellField -Vm (New-VmWithPowerShellJson '{ "version": 7.6 }') } |
                Should -Throw -ExpectedMessage '*must be a string*'
        }
    }

    # ------------------------------------------------------------------
    Context 'strict sub-field set' {
    # ------------------------------------------------------------------

        It 'rejects an unknown sub-field and lists what is allowed' {
            $vm = New-VmWithPowerShellJson '{ "version": "7.6.4", "versoin": "7" }'
            { Assert-PowerShellField -Vm $vm } |
                Should -Throw -ExpectedMessage "*unknown sub-field 'versoin'*Allowed sub-fields: version*"
        }

        # There is no 'vendor' knob: Microsoft is the only publisher, so the
        # field would be dead data. Rejecting it keeps that explicit rather
        # than silently ignored.
        It 'rejects a vendor sub-field' {
            $vm = New-VmWithPowerShellJson '{ "version": "7.6.4", "vendor": "microsoft" }'
            { Assert-PowerShellField -Vm $vm } |
                Should -Throw -ExpectedMessage "*unknown sub-field 'vendor'*"
        }

        It 'rejects an entry missing version' {
            { Assert-PowerShellField -Vm (New-VmWithPowerShellJson '{}') } |
                Should -Throw -ExpectedMessage "*missing required sub-field 'version'*"
        }

        It 'rejects a non-object list entry' {
            { Assert-PowerShellField -Vm (New-VmWithPowerShellJson '["7.6.4"]') } |
                Should -Throw -ExpectedMessage "*entry must be a JSON object with a 'version' sub-field*"
        }
    }

    # ------------------------------------------------------------------
    Context 'v1 single-version cap' {
    # ------------------------------------------------------------------

        It 'rejects a list of two entries and names the count' {
            $vm = New-VmWithPowerShellJson '[{ "version": "7.6.4" }, { "version": "7.5.9" }]'
            { Assert-PowerShellField -Vm $vm } |
                Should -Throw -ExpectedMessage '*list of 2 entries*one PowerShell per VM*'
        }
    }

    # ------------------------------------------------------------------
    Context 'diagnostics' {
    # ------------------------------------------------------------------

        # Every message must name the VM: an operator editing a multi-VM
        # config needs to know which entry tripped the check.
        It 'names the VM in the error message' {
            $vm = '{ "vmName": "runner-07", "powershell": { "version": "nope" } }' |
                ConvertFrom-Json

            { Assert-PowerShellField -Vm $vm } |
                Should -Throw -ExpectedMessage "*VM 'runner-07': powershell*"
        }

        It 'falls back to (unknown) when the VM has no name' {
            $vm = '{ "powershell": { "version": "nope" } }' | ConvertFrom-Json

            { Assert-PowerShellField -Vm $vm } |
                Should -Throw -ExpectedMessage '*(unknown)*'
        }
    }
}
