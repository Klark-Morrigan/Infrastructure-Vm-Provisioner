BeforeAll {
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\common\config\Group-VmsByEnvironment.ps1"

    function New-Vm {
        param(
            [string] $VmName,
            [string] $Kind              = 'workload',
            [string] $PrivateSwitchName = 'env-prod'
        )
        [PSCustomObject]@{
            vmName            = $VmName
            kind              = $Kind
            privateSwitchName = $PrivateSwitchName
        }
    }
}

Describe 'Group-VmsByEnvironment' {

    # ------------------------------------------------------------------
    Context 'shape of the returned record' {
    # ------------------------------------------------------------------

        It 'returns one record per unique privateSwitchName' {
            $vms = @(
                (New-Vm 'router-prod' -Kind 'router' -PrivateSwitchName 'env-prod'),
                (New-Vm 'node-01'                    -PrivateSwitchName 'env-prod'),
                (New-Vm 'router-dev'  -Kind 'router' -PrivateSwitchName 'env-dev')
            )
            $result = @(Group-VmsByEnvironment -VmDefs $vms)
            $result.Count | Should -Be 2
        }

        It 'returns the privateSwitchName in the Name field' {
            $result = @(Group-VmsByEnvironment -VmDefs @(
                (New-Vm 'node-01' -PrivateSwitchName 'env-prod')))
            $result[0].Name | Should -Be 'env-prod'
        }

        It 'partitions router VMs into RouterVms and the rest into WorkloadVms' {
            $vms = @(
                (New-Vm 'router-prod' -Kind 'router'),
                (New-Vm 'node-01'),
                (New-Vm 'node-02')
            )
            $result = @(Group-VmsByEnvironment -VmDefs $vms)
            $result[0].RouterVms.Count   | Should -Be 1
            $result[0].RouterVms[0].vmName | Should -Be 'router-prod'
            $result[0].WorkloadVms.Count | Should -Be 2
        }

        It 'returns RouterVms / WorkloadVms with a Count property when one side is absent' {
            # Callers iterate these with foreach and inspect .Count;
            # returning $null instead of an empty array would break the
            # Count access. PSCustomObject wrapping by Pester does not
            # preserve the empty-array type reliably, so the contract is
            # asserted via .Count rather than -BeOfType.
            $vms = @( (New-Vm 'node-01') )
            $result = @(Group-VmsByEnvironment -VmDefs $vms)
            $result[0].RouterVms.Count   | Should -Be 0
            $result[0].WorkloadVms.Count | Should -Be 1
        }
    }

    # ------------------------------------------------------------------
    Context 'edge cases' {
    # ------------------------------------------------------------------

        It 'returns an empty array on an empty input' {
            $result = @(Group-VmsByEnvironment -VmDefs @())
            $result.Count | Should -Be 0
        }

        It 'tolerates multiple router VMs in one environment (no validation here)' {
            # Validation lives in Assert-EnvironmentConsistency; this
            # helper is pure grouping so deprovision can call it against
            # any config shape without preflight running first.
            $vms = @(
                (New-Vm 'router-a' -Kind 'router'),
                (New-Vm 'router-b' -Kind 'router')
            )
            $result = @(Group-VmsByEnvironment -VmDefs $vms)
            $result[0].RouterVms.Count | Should -Be 2
        }

        It 'preserves source order within each environment' {
            # Per-VM error messages reference VMs in the order the
            # operator wrote them; this helper must not reshuffle.
            $vms = @(
                (New-Vm 'node-03'),
                (New-Vm 'node-01'),
                (New-Vm 'node-02')
            )
            $result = @(Group-VmsByEnvironment -VmDefs $vms)
            $result[0].WorkloadVms[0].vmName | Should -Be 'node-03'
            $result[0].WorkloadVms[1].vmName | Should -Be 'node-01'
            $result[0].WorkloadVms[2].vmName | Should -Be 'node-02'
        }
    }
}
