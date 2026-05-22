BeforeAll {
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\seed\New-StaticNetplanYaml.ps1"

    function New-TestYaml {
        New-StaticNetplanYaml `
            -IpAddress  '192.168.1.10' `
            -SubnetMask '24' `
            -Gateway    '192.168.1.1' `
            -Dns        '8.8.8.8'
    }
}

Describe 'New-StaticNetplanYaml' {

    # ------------------------------------------------------------------
    Context 'output shape' {
    # ------------------------------------------------------------------

        It 'returns a single string' {
            $yaml = New-TestYaml
            $yaml | Should -BeOfType ([string])
        }

        It 'declares netplan v2 schema' {
            (New-TestYaml) | Should -Match '(?m)^version: 2$'
        }

        It 'configures the eth0 ethernet entry' {
            (New-TestYaml) | Should -Match '(?ms)^ethernets:\s*\r?\n\s+eth0:'
        }

        It 'matches the Hyper-V synthetic NIC by driver' {
            # Driver match keeps the file working across kernel NIC names
            # (eth0, enp0s*, etc.) which differ between Ubuntu releases.
            (New-TestYaml) | Should -Match 'driver: hv_netvsc'
        }

        It 'disables DHCPv4 so the static address is authoritative' {
            (New-TestYaml) | Should -Match 'dhcp4: false'
        }
    }

    # ------------------------------------------------------------------
    Context 'address composition' {
    # ------------------------------------------------------------------

        It 'composes CIDR from IpAddress and SubnetMask' {
            (New-TestYaml) | Should -Match '- 192\.168\.1\.10/24'
        }

        It 'reflects the supplied IpAddress' {
            $yaml = New-StaticNetplanYaml `
                -IpAddress  '10.20.30.40' `
                -SubnetMask '16' `
                -Gateway    '10.20.0.1' `
                -Dns        '1.1.1.1'
            $yaml | Should -Match '- 10\.20\.30\.40/16'
        }

        It 'reflects the supplied SubnetMask' {
            $yaml = New-StaticNetplanYaml `
                -IpAddress  '192.168.1.10' `
                -SubnetMask '23' `
                -Gateway    '192.168.1.1' `
                -Dns        '8.8.8.8'
            $yaml | Should -Match '- 192\.168\.1\.10/23'
        }
    }

    # ------------------------------------------------------------------
    Context 'default route' {
    # ------------------------------------------------------------------

        It 'uses the supplied Gateway as the default route via' {
            (New-TestYaml) | Should -Match '(?ms)- to: default\s*\r?\n\s+via: 192\.168\.1\.1'
        }

        It 'reflects a different Gateway when changed' {
            $yaml = New-StaticNetplanYaml `
                -IpAddress  '192.168.1.10' `
                -SubnetMask '24' `
                -Gateway    '192.168.99.254' `
                -Dns        '8.8.8.8'
            $yaml | Should -Match 'via: 192\.168\.99\.254'
        }
    }

    # ------------------------------------------------------------------
    Context 'DNS' {
    # ------------------------------------------------------------------

        It 'lists only the supplied DNS server under nameservers' {
            $yaml = New-TestYaml
            $yaml | Should -Match '(?ms)nameservers:\s*\r?\n\s+addresses:\s*\r?\n\s+- 8\.8\.8\.8'
        }

        It 'does not include any DNS address other than the one supplied' {
            # Guards against accidentally hard-coding a fallback (e.g. 1.1.1.1).
            $yaml = New-StaticNetplanYaml `
                -IpAddress  '192.168.1.10' `
                -SubnetMask '24' `
                -Gateway    '192.168.1.1' `
                -Dns        '9.9.9.9'
            $addresses = [regex]::Matches(
                $yaml,
                '(?<!\d)(?:\d{1,3}\.){3}\d{1,3}(?!\d|/)'
            ) | ForEach-Object { $_.Value }
            # Expected non-DNS addresses in the document: gateway + host IP.
            $dnsAddresses = $addresses | Where-Object {
                $_ -ne '192.168.1.10' -and $_ -ne '192.168.1.1'
            }
            $dnsAddresses | Should -Be @('9.9.9.9')
        }
    }
}
