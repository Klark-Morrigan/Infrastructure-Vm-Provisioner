BeforeAll {
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\network\setup-network.ps1"

    # Behaviour of the shared cleanup helper lives in its own test file
    # (Tests/common/network/Remove-LegacySingletonNat.Tests.ps1). Here we
    # only need a stub so the wiring tests can assert it is called.
    function Remove-LegacySingletonNat { param([string]$GatewayIp) }

    function New-RouterVm {
        param(
            [string] $PrivateSwitchName = 'PrivateSwitch-Production',
            [string] $PrivateIpAddress  = '10.10.0.1'
        )
        [PSCustomObject]@{
            vmName            = 'router-prod'
            privateSwitchName = $PrivateSwitchName
            privateIpAddress  = $PrivateIpAddress
        }
    }
}

Describe 'Invoke-NetworkSetup' {

    # ------------------------------------------------------------------
    Context 'delegation to Remove-LegacySingletonNat' {
    # ------------------------------------------------------------------
        # Behaviour of the cleanup itself - which NetNat to remove, which
        # vNIC IP to unassign - lives next to the helper. This caller's
        # tests pin only the wiring contract: the function calls the
        # shared helper once per invocation, with the router VM's gateway
        # IP, regardless of whether workload VMs are present.

        It 'calls Remove-LegacySingletonNat exactly once' {
            Mock Remove-LegacySingletonNat { }
            Invoke-NetworkSetup -RouterVm (New-RouterVm) -WorkloadVms @()
            Should -Invoke Remove-LegacySingletonNat -Times 1 -Exactly
        }

        It "passes the router VM's privateIpAddress as -GatewayIp" {
            # The cleanup is scoped to this environment, not the workloads:
            # the gateway IP comes from the router VM definition. Pins
            # that wiring so a refactor cannot silently swap to a
            # workload-derived value.
            Mock Remove-LegacySingletonNat { }
            Invoke-NetworkSetup -RouterVm    (New-RouterVm -PrivateIpAddress '10.10.0.1') `
                                -WorkloadVms @()
            Should -Invoke Remove-LegacySingletonNat -Times 1 -Exactly -ParameterFilter {
                $GatewayIp -eq '10.10.0.1'
            }
        }

        It 'runs the cleanup even on a router-only batch (empty WorkloadVms)' {
            # A stale host-side NetNat / vNIC IP must be cleaned up the
            # first time the router VM is provisioned, before any
            # workloads come along.
            Mock Remove-LegacySingletonNat { }
            Invoke-NetworkSetup -RouterVm (New-RouterVm) -WorkloadVms @()
            Should -Invoke Remove-LegacySingletonNat -Times 1 -Exactly
        }
    }
}
