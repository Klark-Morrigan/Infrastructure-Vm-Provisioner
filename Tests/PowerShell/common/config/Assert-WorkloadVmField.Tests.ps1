BeforeAll {
    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\common\config\Assert-WorkloadVmField.ps1"

    function New-WorkloadVm {
        [PSCustomObject]@{
            vmName     = 'node-01'
            ipAddress  = '10.10.0.10'
            subnetMask = '24'
            gateway    = '10.10.0.1'
        }
    }
}

Describe 'Assert-WorkloadVmField' {

    # ------------------------------------------------------------------
    Context 'required static-address fields' {
    # ------------------------------------------------------------------
        # Workload VMs always need a static IP / subnetMask / gateway -
        # the gateway equals the env's router VM's privateIpAddress
        # (a config-time choice no DHCP path can pre-commit to).

        It 'returns silently when ipAddress / subnetMask / gateway are all present' {
            { Assert-WorkloadVmField -Vm (New-WorkloadVm) } | Should -Not -Throw
        }

        It 'throws when ipAddress is missing' {
            $vm = New-WorkloadVm
            $vm.PSObject.Properties.Remove('ipAddress')
            { Assert-WorkloadVmField -Vm $vm } |
                Should -Throw -ExpectedMessage "*ipAddress*"
        }

        It 'throws when gateway is missing' {
            $vm = New-WorkloadVm
            $vm.PSObject.Properties.Remove('gateway')
            { Assert-WorkloadVmField -Vm $vm } |
                Should -Throw -ExpectedMessage "*gateway*"
        }

        It 'throws when a required field is empty' {
            $vm = New-WorkloadVm
            $vm.ipAddress = ''
            { Assert-WorkloadVmField -Vm $vm } |
                Should -Throw -ExpectedMessage "*non-empty*"
        }

        It 'throws when a required field is whitespace-only' {
            $vm = New-WorkloadVm
            $vm.gateway = '   '
            { Assert-WorkloadVmField -Vm $vm } |
                Should -Throw -ExpectedMessage "*non-empty*"
        }
    }

    # ------------------------------------------------------------------
    Context 'error context' {
    # ------------------------------------------------------------------

        It 'includes the vmName and "workload" in the error context' {
            $vm = New-WorkloadVm
            $vm.PSObject.Properties.Remove('ipAddress')
            { Assert-WorkloadVmField -Vm $vm } |
                Should -Throw -ExpectedMessage "*node-01*workload*"
        }

        It 'falls back to (unknown) when vmName is absent' {
            $vm = New-WorkloadVm
            $vm.PSObject.Properties.Remove('vmName')
            $vm.PSObject.Properties.Remove('ipAddress')
            { Assert-WorkloadVmField -Vm $vm } |
                Should -Throw -ExpectedMessage "*(unknown)*"
        }
    }
}
