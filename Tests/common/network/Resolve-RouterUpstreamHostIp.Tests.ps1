BeforeAll {
    # Get-NetIPAddress is a Windows-only cmdlet from the NetTCPIP module.
    # Stub it at script scope so the test file runs on any platform and
    # the implementation's call site is rebound onto the mock.
    function Get-NetIPAddress { param($AddressFamily) }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\common\network\Resolve-RouterUpstreamHostIp.ps1"
}

Describe 'Resolve-RouterUpstreamHostIp' {

    # ------------------------------------------------------------------
    Context 'happy path - host adapter on same /24 as router' {
    # ------------------------------------------------------------------

        It 'returns the host IP that shares the /24 prefix with the router' {
            Mock Get-NetIPAddress {
                @(
                    [PSCustomObject]@{ IPAddress = '127.0.0.1'     },
                    [PSCustomObject]@{ IPAddress = '192.168.1.42'  },
                    [PSCustomObject]@{ IPAddress = '10.0.0.5'      }
                )
            }

            Resolve-RouterUpstreamHostIp -RouterIpAddress '192.168.1.211' |
                Should -Be '192.168.1.42'
        }

        It 'tolerates different last octets within the /24' {
            Mock Get-NetIPAddress {
                @([PSCustomObject]@{ IPAddress = '192.168.1.1' })
            }

            Resolve-RouterUpstreamHostIp -RouterIpAddress '192.168.1.254' |
                Should -Be '192.168.1.1'
        }
    }

    # ------------------------------------------------------------------
    Context 'host IP collisions with the router IP itself' {
    # ------------------------------------------------------------------
        # Defensive: the router and host should not share an IP, but if
        # the prefix matches multiple host adapters and one of them
        # equals the router's IP, the function must skip it.

        It 'skips an entry equal to the router IP' {
            Mock Get-NetIPAddress {
                @(
                    [PSCustomObject]@{ IPAddress = '192.168.1.211' },
                    [PSCustomObject]@{ IPAddress = '192.168.1.42'  }
                )
            }

            Resolve-RouterUpstreamHostIp -RouterIpAddress '192.168.1.211' |
                Should -Be '192.168.1.42'
        }
    }

    # ------------------------------------------------------------------
    Context 'no matching adapter' {
    # ------------------------------------------------------------------

        It 'throws with the router IP and prefix in the message' {
            Mock Get-NetIPAddress {
                @(
                    [PSCustomObject]@{ IPAddress = '10.0.0.5'  },
                    [PSCustomObject]@{ IPAddress = '172.16.0.1' }
                )
            }

            { Resolve-RouterUpstreamHostIp -RouterIpAddress '192.168.1.211' } |
                Should -Throw -ExpectedMessage "*'192.168.1.211'*'192.168.1.'*"
        }

        It 'throws when the only same-prefix entry is the router IP' {
            Mock Get-NetIPAddress {
                @([PSCustomObject]@{ IPAddress = '192.168.1.211' })
            }

            { Resolve-RouterUpstreamHostIp -RouterIpAddress '192.168.1.211' } |
                Should -Throw -ExpectedMessage "*'192.168.1.211'*"
        }
    }

    # ------------------------------------------------------------------
    Context 'first match wins' {
    # ------------------------------------------------------------------

        It 'returns the first same-prefix entry when multiple match' {
            # Deterministic pick - Get-NetIPAddress's enumeration order
            # is the contract.
            Mock Get-NetIPAddress {
                @(
                    [PSCustomObject]@{ IPAddress = '192.168.1.5'  },
                    [PSCustomObject]@{ IPAddress = '192.168.1.42' }
                )
            }

            Resolve-RouterUpstreamHostIp -RouterIpAddress '192.168.1.211' |
                Should -Be '192.168.1.5'
        }
    }
}
