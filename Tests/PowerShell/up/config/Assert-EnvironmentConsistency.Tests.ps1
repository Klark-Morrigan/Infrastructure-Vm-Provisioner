BeforeAll {
    # Assert-EnvironmentConsistency delegates grouping to
    # Group-VmsByEnvironment. Dot-source the real helper so this test
    # exercises the two together (the helper's own contract is covered
    # in Tests/common/config/Group-VmsByEnvironment.Tests.ps1).
    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\common\config\Group-VmsByEnvironment.ps1"
    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\up\config\Assert-EnvironmentConsistency.ps1"

    function New-WorkloadVm {
        param(
            [string] $VmName            = 'node-01',
            [string] $Gateway           = '10.10.0.1',
            [string] $SubnetMask        = '24',
            [string] $PrivateSwitchName = 'PrivateSwitch-Production'
        )
        [PSCustomObject]@{
            vmName            = $VmName
            gateway           = $Gateway
            subnetMask        = $SubnetMask
            privateSwitchName = $PrivateSwitchName
            kind              = 'workload'
        }
    }

    function New-RouterVm {
        param(
            [string] $VmName            = 'router-prod',
            [string] $PrivateIpAddress  = '10.10.0.1',
            # Upstream LAN gateway - the router's default route. By
            # design distinct from privateIpAddress: the router has
            # two NICs and its 'gateway' field describes the upstream
            # one. Defaulting to 192.168.1.1 reflects the real schema
            # (a typical LAN gateway) rather than the privateIpAddress
            # fiction the earlier shape used.
            [string] $Gateway           = '192.168.1.1',
            [string] $SubnetMask        = '24',
            [string] $PrivateSwitchName = 'PrivateSwitch-Production'
        )
        [PSCustomObject]@{
            vmName            = $VmName
            gateway           = $Gateway
            subnetMask        = $SubnetMask
            privateSwitchName = $PrivateSwitchName
            kind              = 'router'
            privateIpAddress  = $PrivateIpAddress
        }
    }
}

Describe 'Assert-EnvironmentConsistency' {

    # ------------------------------------------------------------------
    Context 'accepted batches' {
    # ------------------------------------------------------------------

        It 'accepts a router-only environment (bootstrap path)' {
            { Assert-EnvironmentConsistency -VmDefs @((New-RouterVm)) } |
                Should -Not -Throw
        }

        It 'accepts one router and one workload sharing gateway and switch' {
            $vms = @(
                (New-RouterVm),
                (New-WorkloadVm -Gateway '10.10.0.1')
            )
            { Assert-EnvironmentConsistency -VmDefs $vms } | Should -Not -Throw
        }

        It "accepts a router with a distinct upstream gateway (real schema)" {
            # Regression for the case the earlier validator wrongly
            # rejected: the router's top-level 'gateway' describes its
            # UPSTREAM NIC (a real LAN gateway) and is necessarily on
            # a different subnet than the workloads' 'gateway' (which
            # equals the router's privateIpAddress). Both shapes must
            # coexist in one environment without preflight failing.
            $vms = @(
                (New-RouterVm   -PrivateIpAddress '10.10.0.1' -Gateway '192.168.1.1'),
                (New-WorkloadVm -Gateway          '10.10.0.1')
            )
            { Assert-EnvironmentConsistency -VmDefs $vms } | Should -Not -Throw
        }

        It "throws when the router's subnetMask differs from the workloads'" {
            # The router's downstream NIC sits on the workloads'
            # private subnet (the schema reuses the single subnetMask
            # field for both router NICs), so the masks must match.
            $vms = @(
                (New-RouterVm   -PrivateIpAddress '10.10.0.1' -SubnetMask '16'),
                (New-WorkloadVm -Gateway          '10.10.0.1' -SubnetMask '24')
            )
            { Assert-EnvironmentConsistency -VmDefs $vms } |
                Should -Throw -ExpectedMessage "*subnetMask*"
        }

        It 'accepts two independent environments side by side' {
            $vms = @(
                (New-RouterVm   -VmName 'router-prod'  -PrivateSwitchName 'env-prod' -PrivateIpAddress '10.10.0.1'),
                (New-WorkloadVm -VmName 'prod-node-01' -PrivateSwitchName 'env-prod' -Gateway          '10.10.0.1'),
                (New-RouterVm   -VmName 'router-dev'   -PrivateSwitchName 'env-dev'  -PrivateIpAddress '10.20.0.1'),
                (New-WorkloadVm -VmName 'dev-node-01'  -PrivateSwitchName 'env-dev'  -Gateway          '10.20.0.1')
            )
            { Assert-EnvironmentConsistency -VmDefs $vms } | Should -Not -Throw
        }
    }

    # ------------------------------------------------------------------
    Context 'shared gateway / subnet within an environment' {
    # ------------------------------------------------------------------

        It 'throws when workload VMs in one env declare mismatched gateways' {
            $vms = @(
                (New-RouterVm),
                (New-WorkloadVm -VmName 'node-01' -Gateway '10.10.0.1'),
                (New-WorkloadVm -VmName 'node-02' -Gateway '10.10.0.99')
            )
            { Assert-EnvironmentConsistency -VmDefs $vms } |
                Should -Throw -ExpectedMessage "*gateway*"
        }

        It 'throws when workload VMs in one env declare mismatched subnet masks' {
            $vms = @(
                (New-RouterVm),
                (New-WorkloadVm -VmName 'node-01' -SubnetMask '24'),
                (New-WorkloadVm -VmName 'node-02' -SubnetMask '16')
            )
            { Assert-EnvironmentConsistency -VmDefs $vms } |
                Should -Throw -ExpectedMessage "*subnetMask*"
        }
    }

    # ------------------------------------------------------------------
    Context 'router VM rules (when workloads are present)' {
    # ------------------------------------------------------------------

        It 'throws when an environment has workloads but no router VM' {
            $vms = @(
                (New-WorkloadVm -VmName 'node-01'),
                (New-WorkloadVm -VmName 'node-02')
            )
            { Assert-EnvironmentConsistency -VmDefs $vms } |
                Should -Throw -ExpectedMessage "*no router VM*"
        }

        It 'throws when one environment has two router VMs' {
            $vms = @(
                (New-RouterVm   -VmName 'router-a'),
                (New-RouterVm   -VmName 'router-b'),
                (New-WorkloadVm -VmName 'node-01' -Gateway '10.10.0.1')
            )
            { Assert-EnvironmentConsistency -VmDefs $vms } |
                Should -Throw -ExpectedMessage "*exactly one*"
        }

        It "throws when the router's privateIpAddress does not match the workloads' gateway" {
            # Workloads route their egress through the router, so the
            # router's private NIC IP must equal the workloads' gateway.
            $vms = @(
                (New-RouterVm   -PrivateIpAddress '10.10.0.1'),
                (New-WorkloadVm -Gateway          '10.10.0.99')
            )
            { Assert-EnvironmentConsistency -VmDefs $vms } |
                Should -Throw -ExpectedMessage "*gateway*"
        }
    }
}
