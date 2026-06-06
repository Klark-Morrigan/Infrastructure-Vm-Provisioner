BeforeAll {
    function Get-NetNat          { param($ErrorAction) }
    function Remove-NetNat       { param([string]$Name, [switch]$Confirm) }
    function Get-NetIPAddress    { param([string]$IPAddress, $ErrorAction) }
    function Remove-NetIPAddress { param([string]$IPAddress, [switch]$Confirm) }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\common\network\Remove-LegacySingletonNat.ps1"

    function Initialize-NoLegacyMocks {
        Mock Get-NetNat       { @() }
        Mock Get-NetIPAddress { $null }
        Mock Remove-NetNat       { }
        Mock Remove-NetIPAddress { }
    }
}

Describe 'Remove-LegacySingletonNat' {

    # ------------------------------------------------------------------
    Context 'no legacy state present (already-migrated host)' {
    # ------------------------------------------------------------------

        It 'does not call Remove-NetNat when no NetNat covers the gateway' {
            Initialize-NoLegacyMocks
            Remove-LegacySingletonNat -GatewayIp '10.10.0.1'
            Should -Invoke Remove-NetNat -Times 0
        }

        It 'does not call Remove-NetIPAddress when no host vNIC has the gateway IP' {
            Initialize-NoLegacyMocks
            Remove-LegacySingletonNat -GatewayIp '10.10.0.1'
            Should -Invoke Remove-NetIPAddress -Times 0
        }
    }

    # ------------------------------------------------------------------
    Context 'NetNat sweep' {
    # ------------------------------------------------------------------

        It 'removes a NetNat whose prefix covers the gateway IP' {
            Initialize-NoLegacyMocks
            Mock Get-NetNat {
                @([PSCustomObject]@{
                    Name                            = 'VmLAN-NAT'
                    InternalIPInterfaceAddressPrefix = '10.10.0.0/24'
                })
            }
            Remove-LegacySingletonNat -GatewayIp '10.10.0.1'
            # -Confirm:$false binds the SwitchParameter to $false; the
            # filter inspects the bound value to confirm callers cannot
            # surface a confirmation prompt that would block CI.
            Should -Invoke Remove-NetNat -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'VmLAN-NAT' -and $Confirm -eq $false
            }
        }

        It 'leaves NetNat rules covering other subnets untouched' {
            # Scoping by network prefix (not by name) is the contract
            # callers depend on - sibling environments must survive a
            # cleanup pass for one of their neighbours.
            Initialize-NoLegacyMocks
            Mock Get-NetNat {
                @([PSCustomObject]@{
                    Name                            = 'Other-NAT'
                    InternalIPInterfaceAddressPrefix = '10.20.0.0/24'
                })
            }
            Remove-LegacySingletonNat -GatewayIp '10.10.0.1'
            Should -Invoke Remove-NetNat -Times 0
        }

        It 'removes every matching NetNat rule, regardless of name' {
            # The name-agnostic sweep is what makes the cleanup tolerate
            # operator-renamed legacy rules and overlapping prefixes.
            Initialize-NoLegacyMocks
            Mock Get-NetNat {
                @(
                    [PSCustomObject]@{
                        Name                            = 'VmLAN-NAT'
                        InternalIPInterfaceAddressPrefix = '10.10.0.0/24'
                    },
                    [PSCustomObject]@{
                        Name                            = 'Custom-NAT'
                        InternalIPInterfaceAddressPrefix = '10.10.0.0/16'
                    }
                )
            }
            Remove-LegacySingletonNat -GatewayIp '10.10.0.1'
            Should -Invoke Remove-NetNat -Times 2 -Exactly
        }
    }

    # ------------------------------------------------------------------
    Context 'host vNIC IP cleanup' {
    # ------------------------------------------------------------------

        It 'removes the host vNIC IP when it carries the gateway IP' {
            Initialize-NoLegacyMocks
            Mock Get-NetIPAddress { [PSCustomObject]@{ IPAddress = '10.10.0.1' } }
            Remove-LegacySingletonNat -GatewayIp '10.10.0.1'
            Should -Invoke Remove-NetIPAddress -Times 1 -Exactly -ParameterFilter {
                $IPAddress -eq '10.10.0.1' -and $Confirm -eq $false
            }
        }

        It 'queries Get-NetIPAddress with the gateway IP' {
            # Pins the lookup contract: a caller can rely on the cleanup
            # operating exactly on the IP it hands in, not on a derived
            # value.
            Initialize-NoLegacyMocks
            Remove-LegacySingletonNat -GatewayIp '10.10.0.1'
            Should -Invoke Get-NetIPAddress -Times 1 -Exactly -ParameterFilter {
                $IPAddress -eq '10.10.0.1'
            }
        }
    }
}

Describe 'Test-IpInPrefix' {

    # ------------------------------------------------------------------
    Context 'matching and non-matching prefixes' {
    # ------------------------------------------------------------------

        It 'returns true for an IP inside a /24' {
            Test-IpInPrefix -IpAddress '192.168.1.42' -Prefix '192.168.1.0/24' |
                Should -BeTrue
        }

        It 'returns false for an IP outside a /24' {
            Test-IpInPrefix -IpAddress '192.168.2.42' -Prefix '192.168.1.0/24' |
                Should -BeFalse
        }

        It 'returns true for an IP inside a /16' {
            Test-IpInPrefix -IpAddress '10.10.99.7' -Prefix '10.10.0.0/16' |
                Should -BeTrue
        }

        It 'handles a non-byte-aligned prefix length' {
            # /20 covers 192.168.0.0 - 192.168.15.255. The boundary
            # exercises the bitwise mask path rather than the byte-wise
            # fast path.
            Test-IpInPrefix -IpAddress '192.168.15.255' -Prefix '192.168.0.0/20' |
                Should -BeTrue
            Test-IpInPrefix -IpAddress '192.168.16.0'   -Prefix '192.168.0.0/20' |
                Should -BeFalse
        }

        It 'returns false for a malformed prefix string' {
            # No slash separator - the helper returns false rather than
            # throwing, so a malformed entry in Get-NetNat output cannot
            # take the cleanup loop down.
            Test-IpInPrefix -IpAddress '10.10.0.1' -Prefix 'not-a-prefix' |
                Should -BeFalse
        }
    }
}
