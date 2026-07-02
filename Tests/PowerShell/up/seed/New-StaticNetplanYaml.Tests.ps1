BeforeAll {
    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\up\seed\New-StaticNetplanYaml.ps1"

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
        # The function emits a netplan document (top-level `network:`
        # wrapper); descend into it so per-field assertions read
        # naturally.
        return (ConvertFrom-Yaml $Yaml)['network']
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

        It 'wraps the document under a top-level network: key' {
            # netplan rejects /etc/netplan/*.yaml files that lack the
            # network: wrapper. An earlier revision emitted the inner
            # block only and went unnoticed because cloud-init added the
            # wrapper on its way into 50-cloud-init.yaml; once we
            # started writing the file directly via write_files the
            # missing wrapper made netplan apply a no-op and the NIC
            # never received the static IP.
            $raw = ConvertFrom-Yaml (New-TestYaml)
            $raw.Keys | Should -Contain 'network'
            $raw['network'] | Should -BeOfType ([hashtable])
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

    # ------------------------------------------------------------------
    Context 'Key parameter (ethernet entry id)' {
    # ------------------------------------------------------------------

        It 'defaults the ethernet entry key to eth0' {
            $eths = (ConvertTo-NetplanModel -Yaml (New-TestYaml))['ethernets']
            @($eths.Keys) | Should -Be @('eth0')
        }

        It 'uses the supplied Key as the ethernet entry id' {
            $yaml = New-StaticNetplanYaml `
                -Key        'ext0' `
                -IpAddress  '192.168.1.10' `
                -SubnetMask '24' `
                -Gateway    '192.168.1.1' `
                -Dns        '8.8.8.8'
            $eths = (ConvertTo-NetplanModel -Yaml $yaml)['ethernets']
            @($eths.Keys) | Should -Be @('ext0')
        }
    }

    # ------------------------------------------------------------------
    Context 'MacAddress parameter (match by MAC instead of driver)' {
    # ------------------------------------------------------------------
        # Router VMs need MAC-based matching because both NICs share the
        # hv_netvsc driver, so the workload-default driver match is
        # ambiguous. Workload VMs continue to match by driver.

        It 'matches by driver hv_netvsc when MacAddress is absent' {
            $eth = (ConvertTo-NetplanModel -Yaml (New-TestYaml))['ethernets']['eth0']
            $eth['match']['driver']     | Should -Be 'hv_netvsc'
            $eth['match']['macaddress'] | Should -BeNullOrEmpty
        }

        It 'matches by MacAddress when supplied' {
            $yaml = New-StaticNetplanYaml `
                -IpAddress  '192.168.1.10' `
                -SubnetMask '24' `
                -Gateway    '192.168.1.1' `
                -Dns        '8.8.8.8' `
                -MacAddress '02:aa:bb:cc:dd:00'
            $eth = (ConvertTo-NetplanModel -Yaml $yaml)['ethernets']['eth0']
            $eth['match']['macaddress'] | Should -Be '02:aa:bb:cc:dd:00'
            $eth['match']['driver']     | Should -BeNullOrEmpty
        }
    }

    # ------------------------------------------------------------------
    Context 'SetName parameter (pin kernel interface name)' {
    # ------------------------------------------------------------------
        # Router VMs pin set-name so nftables and dnsmasq can reference
        # ext0 / priv0 without guessing at kernel-assigned names.

        It 'omits set-name by default' {
            $eth = (ConvertTo-NetplanModel -Yaml (New-TestYaml))['ethernets']['eth0']
            $eth['set-name'] | Should -BeNullOrEmpty
        }

        It 'emits set-name when supplied' {
            $yaml = New-StaticNetplanYaml `
                -Key        'ext0' `
                -IpAddress  '192.168.1.10' `
                -SubnetMask '24' `
                -Gateway    '192.168.1.1' `
                -Dns        '8.8.8.8' `
                -MacAddress '02:aa:bb:cc:dd:00' `
                -SetName    'ext0'
            $eth = (ConvertTo-NetplanModel -Yaml $yaml)['ethernets']['ext0']
            $eth['set-name'] | Should -Be 'ext0'
        }
    }

    # ------------------------------------------------------------------
    Context 'optional Gateway and Dns' {
    # ------------------------------------------------------------------
        # The router VM's private-side NIC has no upstream gateway and
        # no DNS server (it IS the gateway and resolver for downstream
        # VMs). Skipping the blocks at the template layer keeps the
        # router code from having to do post-hoc YAML surgery.

        It 'omits the routes block when Gateway is absent' {
            $yaml = New-StaticNetplanYaml `
                -IpAddress  '10.10.0.1' `
                -SubnetMask '24' `
                -Dns        '8.8.8.8'
            $eth = (ConvertTo-NetplanModel -Yaml $yaml)['ethernets']['eth0']
            $eth['routes'] | Should -BeNullOrEmpty
        }

        It 'omits the nameservers block when Dns is absent' {
            $yaml = New-StaticNetplanYaml `
                -IpAddress  '10.10.0.1' `
                -SubnetMask '24' `
                -Gateway    '10.10.0.254'
            $eth = (ConvertTo-NetplanModel -Yaml $yaml)['ethernets']['eth0']
            $eth['nameservers'] | Should -BeNullOrEmpty
        }

        It 'omits both routes and nameservers when neither Gateway nor Dns is supplied' {
            $yaml = New-StaticNetplanYaml `
                -IpAddress  '10.10.0.1' `
                -SubnetMask '24'
            $eth = (ConvertTo-NetplanModel -Yaml $yaml)['ethernets']['eth0']
            $eth['routes']      | Should -BeNullOrEmpty
            $eth['nameservers'] | Should -BeNullOrEmpty
            # But the address still lands.
            @($eth['addresses']) | Should -Be @('10.10.0.1/24')
        }
    }

    # ------------------------------------------------------------------
    Context 'NoWrapper switch (ethernet entry only)' {
    # ------------------------------------------------------------------
        # Router VMs compose two ethernet entries under one wrapper to
        # land both NICs in a single netplan document. -NoWrapper lets
        # New-StaticNetplanYaml emit just the inner entry so the caller
        # owns the network: / version: / ethernets: header.

        It 'wraps the entry under network: / version: 2 / ethernets: by default' {
            $yaml = New-TestYaml
            $yaml | Should -Match '(?m)^network:'
            $yaml | Should -Match '(?m)^\s+version:\s*2'
            $yaml | Should -Match '(?m)^\s+ethernets:'
        }

        It 'returns just the ethernet entry when -NoWrapper is set' {
            $entry = New-StaticNetplanYaml `
                -IpAddress  '192.168.1.10' `
                -SubnetMask '24' `
                -Gateway    '192.168.1.1' `
                -Dns        '8.8.8.8' `
                -NoWrapper
            $entry | Should -Not -Match '(?m)^network:'
            $entry | Should -Not -Match '(?m)^\s+version:\s*2'
            $entry | Should -Not -Match '(?m)^\s+ethernets:'
            $entry | Should -Match '(?m)^\s+eth0:'
        }

        It 'concatenated NoWrapper entries parse as one netplan document under a hand-built wrapper' {
            # Pins the composition contract the router seed depends on:
            # two NoWrapper entries can be concatenated under a single
            # `network: / version: 2 / ethernets:` header and the result
            # is a single, parseable netplan document.
            $ext = New-StaticNetplanYaml `
                -Key 'ext0' -MacAddress '02:aa:bb:cc:dd:00' -SetName 'ext0' `
                -IpAddress '192.168.1.10' -SubnetMask '24' `
                -Gateway   '192.168.1.1'  -Dns '8.8.8.8' `
                -NoWrapper
            $priv = New-StaticNetplanYaml `
                -Key 'priv0' -MacAddress '02:aa:bb:cc:dd:01' -SetName 'priv0' `
                -IpAddress '10.10.0.1' -SubnetMask '24' `
                -NoWrapper
            $combined = @"
network:
  version: 2
  ethernets:
$ext
$priv
"@
            $model = ConvertTo-NetplanModel -Yaml $combined
            @($model['ethernets'].Keys) | Sort-Object | Should -Be @('ext0', 'priv0')
            $model['ethernets']['ext0']['match']['macaddress']  | Should -Be '02:aa:bb:cc:dd:00'
            $model['ethernets']['priv0']['match']['macaddress'] | Should -Be '02:aa:bb:cc:dd:01'
            $model['ethernets']['priv0']['routes']              | Should -BeNullOrEmpty
        }
    }
}
