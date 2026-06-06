BeforeAll {
    # Stub Hyper-V cmdlet unavailable outside a Hyper-V host.
    function Get-VM { param($Name, $ErrorAction) }

    # Select-VmsForProvisioning dot-sources Assert-EnvironmentConsistency,
    # which in turn calls Group-VmsByEnvironment. Pull in the real helper
    # so the preflight runs cleanly against test fixtures; behaviour of
    # the preflight rules themselves is covered in
    # Tests/up/config/Assert-EnvironmentConsistency.Tests.ps1.
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\common\config\Group-VmsByEnvironment.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\config\Select-VmsForProvisioning.ps1"

    # Builds a workload VM definition rich enough for the per-environment
    # preflight that runs at the top of Select-VmsForProvisioning. Defaults
    # describe a coherent single-environment batch; tests override fields
    # to exercise specific preflight rules.
    function New-TestVm {
        param(
            [string] $VmName            = 'node-01',
            [string] $IpAddress         = '192.168.1.10',
            [string] $Gateway           = '10.10.0.1',
            [string] $SubnetMask        = '24',
            [string] $PrivateSwitchName = 'PrivateSwitch-Production',
            [string] $Kind              = 'workload'
        )
        [PSCustomObject]@{
            vmName            = $VmName
            ipAddress         = $IpAddress
            gateway           = $Gateway
            subnetMask        = $SubnetMask
            privateSwitchName = $PrivateSwitchName
            kind              = $Kind
        }
    }

    # Builds a router VM definition for the same default environment.
    # privateIpAddress matches the workload's gateway so the env passes
    # the consistency preflight unless the test overrides it.
    function New-RouterVm {
        param(
            [string] $VmName            = 'router-prod',
            [string] $IpAddress         = '192.168.1.2',
            [string] $PrivateIpAddress  = '10.10.0.1',
            [string] $SubnetMask        = '24',
            [string] $PrivateSwitchName = 'PrivateSwitch-Production'
        )
        $vm = New-TestVm `
                  -VmName            $VmName `
                  -IpAddress         $IpAddress `
                  -Gateway           $PrivateIpAddress `
                  -SubnetMask        $SubnetMask `
                  -PrivateSwitchName $PrivateSwitchName `
                  -Kind              'router'
        $vm | Add-Member -MemberType NoteProperty -Name privateIpAddress `
                          -Value $PrivateIpAddress
        $vm
    }

    # Default: no existing VM, no IP conflict (i.e. classified as 'new').
    function Initialize-Mocks {
        Mock Get-VM              { $null  }
        Mock Test-IpAddressInUse { $false }
    }
}

Describe 'Select-VmsForProvisioning' {

    # ------------------------------------------------------------------
    Context 'environment consistency preflight wiring' {
    # ------------------------------------------------------------------
        # The preflight rules themselves are covered in
        # Assert-EnvironmentConsistency.Tests.ps1. Here we only pin the
        # wiring: the function is called once, with the VM defs, before
        # any per-VM classification runs (so a rejected batch never
        # reaches Get-VM / Test-IpAddressInUse).

        It 'invokes Assert-EnvironmentConsistency exactly once with the input VMs' {
            Initialize-Mocks
            Mock Assert-EnvironmentConsistency { }
            @(Select-VmsForProvisioning -VmDefs @((New-RouterVm)))
            Should -Invoke Assert-EnvironmentConsistency -Times 1 -Exactly -ParameterFilter {
                $VmDefs[0].vmName -eq 'router-prod'
            }
        }

        It 'does not classify any VM when the preflight throws' {
            # Pins that classification is gated on preflight success: a
            # rejected batch must not Get-VM or Test-IpAddressInUse, both
            # of which could surface confusing errors on top of the real
            # preflight message.
            Initialize-Mocks
            Mock Assert-EnvironmentConsistency { throw "preflight nope" }
            { Select-VmsForProvisioning -VmDefs @((New-RouterVm)) } |
                Should -Throw -ExpectedMessage "*preflight nope*"
            Should -Invoke Get-VM              -Times 0
            Should -Invoke Test-IpAddressInUse -Times 0
        }
    }

    # ------------------------------------------------------------------
    Context 'new VM (Hyper-V absent, IP free)' {
    # ------------------------------------------------------------------

        It "annotates the VM with _state = 'new' and returns it" {
            Initialize-Mocks

            $result = @(Select-VmsForProvisioning -VmDefs @((New-RouterVm)))

            $result.Count        | Should -Be 1
            $result[0].vmName    | Should -Be 'router-prod'
            $result[0]._state    | Should -Be 'new'
        }
    }

    # ------------------------------------------------------------------
    Context 'existing VM (Hyper-V present, IP responds)' {
    # ------------------------------------------------------------------

        It "annotates the VM with _state = 'existing' and returns it" {
            # The existing VM owns its IP, so a ping response is expected
            # and confirms reachability for downstream reconcile.
            Initialize-Mocks
            Mock Get-VM              { [PSCustomObject]@{ Name = 'router-prod' } }
            Mock Test-IpAddressInUse { $true }

            $result = @(Select-VmsForProvisioning -VmDefs @((New-RouterVm)))

            $result.Count     | Should -Be 1
            $result[0].vmName | Should -Be 'router-prod'
            $result[0]._state | Should -Be 'existing'
        }
    }

    # ------------------------------------------------------------------
    Context 'IP conflict with unknown machine (Hyper-V absent, IP in use)' {
    # ------------------------------------------------------------------

        It 'drops the VM with a warning' {
            Initialize-Mocks
            Mock Test-IpAddressInUse { $true }

            $result = @(Select-VmsForProvisioning -VmDefs @((New-RouterVm)) `
                3> $null)

            $result.Count | Should -Be 0
        }
    }

    # ------------------------------------------------------------------
    Context 'existing VM that is offline (Hyper-V present, IP silent)' {
    # ------------------------------------------------------------------

        It 'drops the VM with a warning' {
            # An offline existing VM would fail post-provisioning at SSH
            # open with an opaque error - surface the state up front
            # instead so the operator can start the VM and re-run.
            Initialize-Mocks
            Mock Get-VM              { [PSCustomObject]@{ Name = 'router-prod' } }
            Mock Test-IpAddressInUse { $false }

            $result = @(Select-VmsForProvisioning -VmDefs @((New-RouterVm)) `
                3> $null)

            $result.Count | Should -Be 0
        }
    }

    # ------------------------------------------------------------------
    Context 'mixed batch' {
    # ------------------------------------------------------------------

        It 'classifies each VM independently and returns only valid ones' {
            Initialize-Mocks
            Mock Get-VM -ParameterFilter { $Name -eq 'router-prod' }  { $null }
            Mock Get-VM -ParameterFilter { $Name -eq 'new-vm' }       { $null }
            Mock Get-VM -ParameterFilter { $Name -eq 'existing-vm' }  {
                [PSCustomObject]@{ Name = 'existing-vm' }
            }
            Mock Get-VM -ParameterFilter { $Name -eq 'conflict-vm' }  { $null }
            Mock Get-VM -ParameterFilter { $Name -eq 'offline-vm' }   {
                [PSCustomObject]@{ Name = 'offline-vm' }
            }

            Mock Test-IpAddressInUse -ParameterFilter { $IpAddress -eq '192.168.1.2' }  { $false }
            Mock Test-IpAddressInUse -ParameterFilter { $IpAddress -eq '10.0.0.1' }     { $false }
            Mock Test-IpAddressInUse -ParameterFilter { $IpAddress -eq '10.0.0.2' }     { $true  }
            Mock Test-IpAddressInUse -ParameterFilter { $IpAddress -eq '10.0.0.3' }     { $true  }
            Mock Test-IpAddressInUse -ParameterFilter { $IpAddress -eq '10.0.0.4' }     { $false }

            $vms = @(
                # Router is in the JSON so the preflight passes for the
                # whole environment. It is classified 'new' alongside
                # 'new-vm'; the other three exercise the failure paths.
                (New-RouterVm),
                (New-TestVm -VmName 'new-vm'      -IpAddress '10.0.0.1'),
                (New-TestVm -VmName 'existing-vm' -IpAddress '10.0.0.2'),
                (New-TestVm -VmName 'conflict-vm' -IpAddress '10.0.0.3'),
                (New-TestVm -VmName 'offline-vm'  -IpAddress '10.0.0.4')
            )

            $result = @(Select-VmsForProvisioning -VmDefs $vms 3> $null)

            $result.Count                                            | Should -Be 3
            ($result | Where-Object vmName -eq 'router-prod')._state | Should -Be 'new'
            ($result | Where-Object vmName -eq 'new-vm')._state      | Should -Be 'new'
            ($result | Where-Object vmName -eq 'existing-vm')._state | Should -Be 'existing'
        }
    }
}
