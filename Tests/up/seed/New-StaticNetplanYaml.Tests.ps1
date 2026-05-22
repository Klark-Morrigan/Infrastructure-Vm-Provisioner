BeforeAll {
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\seed\New-StaticNetplanYaml.ps1"

    # powershell-yaml is a test-only dependency used to round-trip the
    # generated YAML into a hashtable so assertions are made against
    # parsed structure rather than literal whitespace. Installed here on
    # demand because it is not part of Install-ModuleDependencies (which
    # covers production dependencies only).
    if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
        Install-Module powershell-yaml -Scope CurrentUser `
            -Force -AllowClobber -ErrorAction Stop
    }
    Import-Module powershell-yaml -Force -ErrorAction Stop

    function New-TestYaml {
        New-StaticNetplanYaml `
            -IpAddress  '192.168.1.10' `
            -SubnetMask '24' `
            -Gateway    '192.168.1.1' `
            -Dns        '8.8.8.8'
    }

    function ConvertTo-NetplanModel {
        param([Parameter(Mandatory)] [string] $Yaml)
        # ConvertFrom-Yaml returns nested hashtables for mappings and
        # object arrays for sequences. Strict mode is in effect, so the
        # tests use ['key'] access (which returns $null for missing keys)
        # rather than dot access (which throws under strict mode).
        return (ConvertFrom-Yaml $Yaml)
    }
}

Describe 'New-StaticNetplanYaml' {

    # ------------------------------------------------------------------
    Context 'output shape' {
    # ------------------------------------------------------------------

        It 'returns a single string' {
            (New-TestYaml) | Should -BeOfType ([string])
        }

        It 'parses as valid YAML' {
            { ConvertTo-NetplanModel -Yaml (New-TestYaml) } |
                Should -Not -Throw
        }

        It 'declares netplan v2 schema' {
            $model = ConvertTo-NetplanModel -Yaml (New-TestYaml)
            $model['version'] | Should -Be 2
        }

        It 'configures exactly one ethernet entry, keyed eth0' {
            # eth0 is the netplan logical name; the actual kernel NIC is
            # selected by the match block (driver: hv_netvsc).
            $eths = (ConvertTo-NetplanModel -Yaml (New-TestYaml))['ethernets']
            $eths | Should -BeOfType ([hashtable])
            @($eths.Keys) | Should -Be @('eth0')
        }

        It 'matches the Hyper-V synthetic NIC by driver, not by name' {
            # Matching by driver keeps the file portable across kernel
            # NIC names (eth0 / enp0s* / etc.) that differ between Ubuntu
            # releases and Hyper-V generations.
            $eth = (ConvertTo-NetplanModel -Yaml (New-TestYaml))['ethernets']['eth0']
            $eth['match']['driver'] | Should -Be 'hv_netvsc'
        }

        It 'disables DHCPv4 so the static address is authoritative' {
            $eth = (ConvertTo-NetplanModel -Yaml (New-TestYaml))['ethernets']['eth0']
            $eth['dhcp4'] | Should -Be $false
        }
    }

    # ------------------------------------------------------------------
    Context 'address composition' {
    # ------------------------------------------------------------------

        It 'composes a single CIDR address from IpAddress and SubnetMask' {
            $eth = (ConvertTo-NetplanModel -Yaml (New-TestYaml))['ethernets']['eth0']
            @($eth['addresses']) | Should -Be @('192.168.1.10/24')
        }

        It 'reflects the supplied IpAddress and SubnetMask' {
            $yaml = New-StaticNetplanYaml `
                -IpAddress  '10.20.30.40' `
                -SubnetMask '16' `
                -Gateway    '10.20.0.1' `
                -Dns        '1.1.1.1'
            $eth = (ConvertTo-NetplanModel -Yaml $yaml)['ethernets']['eth0']
            @($eth['addresses']) | Should -Be @('10.20.30.40/16')
        }
    }

    # ------------------------------------------------------------------
    Context 'default route' {
    # ------------------------------------------------------------------

        It 'declares a single default route via the supplied Gateway' {
            $eth = (ConvertTo-NetplanModel -Yaml (New-TestYaml))['ethernets']['eth0']
            $routes = @($eth['routes'])
            $routes.Count | Should -Be 1
            $routes[0]['to']  | Should -Be 'default'
            $routes[0]['via'] | Should -Be '192.168.1.1'
        }

        It 'reflects a different Gateway when changed' {
            $yaml = New-StaticNetplanYaml `
                -IpAddress  '192.168.1.10' `
                -SubnetMask '24' `
                -Gateway    '192.168.99.254' `
                -Dns        '8.8.8.8'
            $route = @((ConvertTo-NetplanModel -Yaml $yaml)['ethernets']['eth0']['routes'])[0]
            $route['via'] | Should -Be '192.168.99.254'
        }
    }

    # ------------------------------------------------------------------
    Context 'DNS' {
    # ------------------------------------------------------------------

        It 'lists exactly the supplied DNS server under nameservers' {
            $eth = (ConvertTo-NetplanModel -Yaml (New-TestYaml))['ethernets']['eth0']
            @($eth['nameservers']['addresses']) | Should -Be @('8.8.8.8')
        }

        It 'does not include any DNS address other than the one supplied' {
            # Guards against accidentally hard-coding a fallback resolver.
            $yaml = New-StaticNetplanYaml `
                -IpAddress  '192.168.1.10' `
                -SubnetMask '24' `
                -Gateway    '192.168.1.1' `
                -Dns        '9.9.9.9'
            $eth = (ConvertTo-NetplanModel -Yaml $yaml)['ethernets']['eth0']
            @($eth['nameservers']['addresses']) | Should -Be @('9.9.9.9')
        }
    }
}
