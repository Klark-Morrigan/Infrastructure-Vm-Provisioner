BeforeAll {
    # Hyper-V cmdlets unavailable outside a Hyper-V host. The shared
    # NetNat / vNIC sweep is owned by Remove-LegacySingletonNat (tested
    # in Tests/common/network/), so its own cmdlets are not stubbed here -
    # the helper is mocked at the boundary instead.
    function Get-VM               { param($ErrorAction) }
    function Get-VMNetworkAdapter { param($VM, $ErrorAction) }
    function Get-VMSwitch         { param([string]$Name, $ErrorAction) }
    function Remove-VMSwitch      { param([string]$Name, [switch]$Force) }

    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\down\network\teardown-network.ps1"

    # Boundary stub for the shared legacy-cleanup helper. Behaviour is
    # asserted in Remove-LegacySingletonNat.Tests.ps1.
    function Remove-LegacySingletonNat { param([string]$GatewayIp) }

    # Boundary stub for the Infrastructure.Network.Windows relay remover.
    # Its own behaviour (and the portproxy/firewall halves it composes) is
    # covered in that module's Tests/Relay; here we assert only the
    # teardown wiring.
    function Remove-RouterSshRelay {
        param([string]$ConnectAddress, [int]$ConnectPort, [int]$ListenPort)
    }

    # Sets up all probes to "no VMs attached and no switch present" so
    # the full teardown path runs without error.
    function Initialize-CleanHostMocks {
        Mock Get-VM                          { }
        Mock Get-VMNetworkAdapter            { }
        Mock Get-VMSwitch                    { $null }
        Mock Remove-VMSwitch                 { }
        Mock Remove-LegacySingletonNat       { }
        Mock Remove-RouterSshRelay           { }
    }
}

Describe 'Invoke-NetworkTeardown' {

    # ------------------------------------------------------------------
    Context 'delegation to Remove-LegacySingletonNat' {
    # ------------------------------------------------------------------

        It 'calls Remove-LegacySingletonNat once with the gateway IP' {
            Initialize-CleanHostMocks
            Invoke-NetworkTeardown -PrivateSwitchName 'env-prod' `
                                   -GatewayIp         '10.10.0.1'
            Should -Invoke Remove-LegacySingletonNat -Times 1 -Exactly -ParameterFilter {
                $GatewayIp -eq '10.10.0.1'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'host-side SSH relay removal' {
    # ------------------------------------------------------------------
        # Symmetric teardown of provision's Set-RouterSshRelay via
        # Remove-RouterSshRelay. Keyed on the router's external IP;
        # self-skips when none is known.

        It 'removes the relay for the router external IP when supplied' {
            Initialize-CleanHostMocks
            Invoke-NetworkTeardown -PrivateSwitchName 'env-prod' `
                                   -GatewayIp         '10.10.0.1' `
                                   -RouterExternalIp  '192.168.137.11'

            Should -Invoke Remove-RouterSshRelay -Times 1 -Exactly -ParameterFilter {
                $ConnectAddress -eq '192.168.137.11'
            }
        }

        It 'threads a custom listen port to the relay remover' {
            Initialize-CleanHostMocks
            Invoke-NetworkTeardown -PrivateSwitchName   'env-prod' `
                                   -GatewayIp           '10.10.0.1' `
                                   -RouterExternalIp    '192.168.137.11' `
                                   -PortProxyListenPort 8222

            Should -Invoke Remove-RouterSshRelay -Times 1 -Exactly -ParameterFilter {
                $ListenPort -eq 8222
            }
        }

        It 'skips relay removal when no router external IP is supplied' {
            # Legacy / workload-only environments and DHCP routers have no
            # config-time external IP; the relay step must self-skip.
            Initialize-CleanHostMocks
            Invoke-NetworkTeardown -PrivateSwitchName 'env-prod' `
                                   -GatewayIp         '10.10.0.1'

            Should -Invoke Remove-RouterSshRelay -Times 0
        }

        It 'skips relay removal when the router external IP is empty' {
            Initialize-CleanHostMocks
            Invoke-NetworkTeardown -PrivateSwitchName 'env-prod' `
                                   -GatewayIp         '10.10.0.1' `
                                   -RouterExternalIp  ''

            Should -Invoke Remove-RouterSshRelay -Times 0
        }
    }

    # ------------------------------------------------------------------
    Context 'attached-VMs guard for the Private switch' {
    # ------------------------------------------------------------------
        # Removing the Private switch while VMs are still attached would
        # cut their network access. The function must bail on switch
        # removal when Get-VMNetworkAdapter reports adapters connected to
        # the named switch. The shared cleanup helper is unaffected -
        # it operates on the gateway IP, not on the switch.

        It 'does not call Remove-VMSwitch when VMs are still attached' {
            Initialize-CleanHostMocks
            Mock Get-VMSwitch { [PSCustomObject]@{ Name = 'env-prod' } }
            Mock Get-VM       { [PSCustomObject]@{ Name = 'node-01' } }
            Mock Get-VMNetworkAdapter {
                [PSCustomObject]@{ SwitchName = 'env-prod'; VMName = 'node-01' }
            }

            Invoke-NetworkTeardown -PrivateSwitchName 'env-prod' `
                                   -GatewayIp         '10.10.0.1'

            Should -Invoke Remove-VMSwitch -Times 0
        }

        It 'does not skip switch removal when a VM is on a different switch' {
            # The guard filters by SwitchName. An adapter on a different
            # switch must not be counted, otherwise the switch teardown
            # would be skipped even though no VMs are on it.
            Initialize-CleanHostMocks
            Mock Get-VMSwitch { [PSCustomObject]@{ Name = 'env-prod' } }
            Mock Get-VM       { [PSCustomObject]@{ Name = 'node-99' } }
            Mock Get-VMNetworkAdapter {
                [PSCustomObject]@{ SwitchName = 'env-dev'; VMName = 'node-99' }
            }

            Invoke-NetworkTeardown -PrivateSwitchName 'env-prod' `
                                   -GatewayIp         '10.10.0.1'

            Should -Invoke Remove-VMSwitch -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'env-prod' -and $Force -eq $true
            }
        }

        It 'uses Get-VM pipeline to check for connected VMs (not Get-VMNetworkAdapter -All)' {
            # VMMS deregisters adapters asynchronously after Remove-VM
            # returns, so Get-VMNetworkAdapter -All transiently reports
            # adapters for VMs that have already been removed - which
            # would incorrectly block teardown.
            Initialize-CleanHostMocks
            Invoke-NetworkTeardown -PrivateSwitchName 'env-prod' `
                                   -GatewayIp         '10.10.0.1'
            Should -Invoke Get-VM -Times 1 -Exactly
        }
    }

    # ------------------------------------------------------------------
    Context 'Private switch removal' {
    # ------------------------------------------------------------------

        It 'removes the Private switch when present and no VMs are attached' {
            Initialize-CleanHostMocks
            Mock Get-VMSwitch { [PSCustomObject]@{ Name = 'env-prod' } }

            Invoke-NetworkTeardown -PrivateSwitchName 'env-prod' `
                                   -GatewayIp         '10.10.0.1'

            Should -Invoke Remove-VMSwitch -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'env-prod' -and $Force -eq $true
            }
        }

        It 'does not call Remove-VMSwitch when the switch is already absent' {
            Initialize-CleanHostMocks
            Invoke-NetworkTeardown -PrivateSwitchName 'env-prod' `
                                   -GatewayIp         '10.10.0.1'
            Should -Invoke Remove-VMSwitch -Times 0
        }
    }
}
