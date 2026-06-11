BeforeAll {
    # New-SeedIso depends on IMAPI2 COM objects unavailable in a headless
    # test environment - stub before dot-sourcing so the reference resolves.
    function New-SeedIso { param($OutputPath, $Files) }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\seed\New-StaticNetplanYaml.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\seed\Get-RouterNicStaticMac.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\seed\Initialize-SeedConfigDirectory.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\seed\New-CloudInitMetaData.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\seed\New-CloudInitUserBlock.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\seed\New-CloudInitDisableNetworkConfigEntry.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\seed\Format-CloudInitLiteralBlock.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\seed\Write-VmSeedIso.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\seed\Invoke-RouterSeedIsoGeneration.ps1"

    # Standard router VM definition - STATIC ext0 (externalDhcp=$false).
    # Fixture content (router-nftables.conf, router-dnsmasq.conf) is keyed
    # to these values; changing them here without updating the fixtures
    # will fail the string-equal checks.
    #
    # The schema default is externalDhcp=$true, but the test fixture pins
    # the static mode explicitly so the netplan-shape assertions below
    # exercise the deterministic path. DHCP-mode coverage lives in its
    # own Context with its own fixture.
    function New-RouterTestVm {
        [PSCustomObject]@{
            vmName              = 'router-prod'
            vmConfigPath        = 'C:\a_VMs\Hyper-V\Config'
            username            = 'admin'
            password            = 'P@ssw0rd'
            ipAddress           = '192.168.1.10'
            subnetMask          = '24'
            gateway             = '192.168.1.1'
            dns                 = '8.8.8.8'
            kind                = 'router'
            externalSwitchName  = 'ExternalSwitch-Shared'
            externalDhcp        = $false
            privateSwitchName   = 'PrivateSwitch-Production'
            privateIpAddress    = '10.10.0.1'
        }
    }

    # DHCP-mode router VM (the schema default). The ext0 NIC gets its
    # address from the LAN's DHCP server, so ipAddress and gateway are
    # absent. subnetMask stays - it pins the priv0 CIDR even under
    # ext0 DHCP. dns also stays - dnsmasq uses it as the upstream
    # forwarder regardless of ext0's addressing.
    function New-DhcpRouterTestVm {
        [PSCustomObject]@{
            vmName              = 'router-prod'
            vmConfigPath        = 'C:\a_VMs\Hyper-V\Config'
            username            = 'admin'
            password            = 'P@ssw0rd'
            subnetMask          = '24'
            dns                 = '8.8.8.8'
            kind                = 'router'
            externalSwitchName  = 'ExternalSwitch-Shared'
            privateSwitchName   = 'PrivateSwitch-Production'
            privateIpAddress    = '10.10.0.1'
        }
    }
}

Describe 'Invoke-RouterSeedIsoGeneration' {

    # ------------------------------------------------------------------
    Context 'vmConfigPath setup' {
    # ------------------------------------------------------------------

        It 'creates vmConfigPath directory when it does not exist' {
            Mock Test-Path { $false }
            Mock New-Item {}
            Mock New-SeedIso {}
            Invoke-RouterSeedIsoGeneration -Vm (New-RouterTestVm)
            Should -Invoke New-Item -Times 1 -Exactly -ParameterFilter {
                $ItemType -eq 'Directory' -and $Path -eq 'C:\a_VMs\Hyper-V\Config'
            }
        }

        It 'does not create vmConfigPath when it already exists' {
            Mock Test-Path { $true }
            Mock New-Item {}
            Mock New-SeedIso {}
            Invoke-RouterSeedIsoGeneration -Vm (New-RouterTestVm)
            Should -Invoke New-Item -Times 0
        }
    }

    # ------------------------------------------------------------------
    Context 'MAC pinning side-effects' {
    # ------------------------------------------------------------------
        # The seed embeds MACs and create-vm.ps1 later sets the same MACs
        # on the Hyper-V adapters. The handoff is by note property on
        # the VM object - this context pins that contract.

        It 'sets _externalMac on the VM object' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            $vm = New-RouterTestVm
            Invoke-RouterSeedIsoGeneration -Vm $vm
            $vm._externalMac | Should -Match '^[0-9a-f]{12}$'
        }

        It 'sets _privateMac on the VM object' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            $vm = New-RouterTestVm
            Invoke-RouterSeedIsoGeneration -Vm $vm
            $vm._privateMac | Should -Match '^[0-9a-f]{12}$'
        }

        It 'sets _externalMac and _privateMac to different values' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            $vm = New-RouterTestVm
            Invoke-RouterSeedIsoGeneration -Vm $vm
            $vm._externalMac | Should -Not -Be $vm._privateMac
        }

        It 'matches the deterministic helper output' {
            # Regression guard: if anyone replaces the MAC source with a
            # non-deterministic generator, the seed and the VM-creation
            # step will silently disagree.
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            $vm = New-RouterTestVm
            $expectedExt  = Get-RouterNicStaticMac -VmName 'router-prod' -Role 'external'
            $expectedPriv = Get-RouterNicStaticMac -VmName 'router-prod' -Role 'private'
            Invoke-RouterSeedIsoGeneration -Vm $vm
            $vm._externalMac | Should -Be $expectedExt.HyperV
            $vm._privateMac  | Should -Be $expectedPriv.HyperV
        }
    }

    # ------------------------------------------------------------------
    Context 'meta-data content' {
    # ------------------------------------------------------------------

        It 'sets instance-id to vmName' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-RouterSeedIsoGeneration -Vm (New-RouterTestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['meta-data'] -match 'instance-id: router-prod'
            }
        }

        It 'sets local-hostname to vmName' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-RouterSeedIsoGeneration -Vm (New-RouterTestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['meta-data'] -match 'local-hostname: router-prod'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'user-data package install (runcmd, not packages:)' {
    # ------------------------------------------------------------------
        # cloud-init's `packages:` block runs in the init stage,
        # BEFORE runcmd's `netplan apply` brings up the static IP.
        # On static-ext0 routers the install times out resolving
        # archive.ubuntu.com (no IPv4 yet) and the units never
        # land, surfacing later as
        # "Unit dnsmasq.service could not be found." The fix is
        # to install via runcmd AFTER `netplan apply` so DNS works.

        It 'does not declare a top-level packages: block' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-RouterSeedIsoGeneration -Vm (New-RouterTestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                # Multiline / case-sensitive: a literal `packages:`
                # at column 0 anywhere in user-data.
                $Files['user-data'] -notmatch '(?m)^packages:'
            }
        }

        It 'installs nftables and dnsmasq via apt-get in runcmd, after netplan apply' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-RouterSeedIsoGeneration -Vm (New-RouterTestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                # netplan apply must precede apt-get install so the
                # install runs against a configured ext0 with DNS.
                $Files['user-data'] -match `
                    "(?s)netplan apply.+?apt-get update.+?apt-get install -y nftables dnsmasq"
            }
        }

        It 'polls DNS readiness with a bounded timeout before apt-get update' {
            # Belt-and-suspenders: even with /etc/resolv.conf written
            # we still wait until at least one resolver answers
            # before firing apt. timeout 120 bounds the wait.
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-RouterSeedIsoGeneration -Vm (New-RouterTestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -match `
                    "timeout 120 sh -c 'until getent hosts archive\.ubuntu\.com"
            }
        }

        It 'wraps apt-get install with DEBIAN_FRONTEND=noninteractive to suppress prompts' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-RouterSeedIsoGeneration -Vm (New-RouterTestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -match 'DEBIAN_FRONTEND=noninteractive apt-get install'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'user-data sysctl payload' {
    # ------------------------------------------------------------------

        It 'writes /etc/sysctl.d/99-router.conf enabling IPv4 forwarding' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-RouterSeedIsoGeneration -Vm (New-RouterTestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -match `
                    "(?s)path: /etc/sysctl\.d/99-router\.conf.*?net\.ipv4\.ip_forward = 1"
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'user-data nftables payload (fixture compare)' {
    # ------------------------------------------------------------------
        # The expected nftables ruleset lives in
        # Tests/up/seed/fixtures/router-nftables.conf so changes to the
        # ruleset are visible in a fixture diff rather than buried in a
        # regex. The fixture is the contract; this test pins it.

        It 'embeds the exact fixture content under /etc/nftables.conf' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}

            $expected = (Get-Content `
                -Path "$PSScriptRoot\fixtures\router-nftables.conf" `
                -Raw) -replace "`r`n", "`n"
            $expectedIndented = ($expected -split "`n" |
                ForEach-Object { "      $_" }) -join "`n"

            Invoke-RouterSeedIsoGeneration -Vm (New-RouterTestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $userData = $Files['user-data'] -replace "`r`n", "`n"
                $userData.Contains($expectedIndented.TrimEnd())
            }
        }

        It 'writes the nftables file with mode 0755' {
            # 0755 because /etc/nftables.conf has a shebang and is
            # executable by convention; nftables.service still loads it
            # via `nft -f /etc/nftables.conf`.
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-RouterSeedIsoGeneration -Vm (New-RouterTestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -match `
                    "(?s)path: /etc/nftables\.conf.*?permissions: '0755'"
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'user-data dnsmasq payload (fixture compare)' {
    # ------------------------------------------------------------------

        It 'embeds the exact fixture content under /etc/dnsmasq.d/router.conf' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}

            $expected = (Get-Content `
                -Path "$PSScriptRoot\fixtures\router-dnsmasq.conf" `
                -Raw) -replace "`r`n", "`n"
            $expectedIndented = ($expected -split "`n" |
                ForEach-Object { "      $_" }) -join "`n"

            Invoke-RouterSeedIsoGeneration -Vm (New-RouterTestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $userData = $Files['user-data'] -replace "`r`n", "`n"
                $userData.Contains($expectedIndented.TrimEnd())
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'user-data dnsmasq drop-in (race-against-networkd fix)' {
    # ------------------------------------------------------------------
        # 2026-06: dnsmasq.service tried to bind 10.99.0.1 before
        # networkd had brought priv0 up, exited 2, and the E2E
        # assertion phase later reported the service as inactive.
        # The seed now ships a systemd drop-in that adds the
        # missing After= dependency plus Restart=on-failure, and
        # runs daemon-reload before enable --now so the override
        # is honoured at first start. These tests lock that in.

        It 'writes /etc/systemd/system/dnsmasq.service.d/10-wait-network.conf' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-RouterSeedIsoGeneration -Vm (New-RouterTestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -match `
                    "(?s)path: /etc/systemd/system/dnsmasq\.service\.d/10-wait-network\.conf.*?permissions: '0644'"
            }
        }

        It 'orders dnsmasq after systemd-networkd-wait-online via the drop-in' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-RouterSeedIsoGeneration -Vm (New-RouterTestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -match 'After=systemd-networkd-wait-online\.service'
            }
        }

        It 'declares Restart=on-failure in the drop-in' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-RouterSeedIsoGeneration -Vm (New-RouterTestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -match 'Restart=on-failure'
            }
        }

        It 'runs systemctl daemon-reload between nftables and dnsmasq enable steps' {
            # daemon-reload must come BEFORE enable --now dnsmasq, so
            # systemd picks up the drop-in at first-start time. After
            # nftables.enable is fine - nftables has no drop-in.
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-RouterSeedIsoGeneration -Vm (New-RouterTestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -match `
                    "(?s)systemctl daemon-reload.*?systemctl enable --now dnsmasq\.service"
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'user-data netplan payload' {
    # ------------------------------------------------------------------

        It 'writes /etc/netplan/99-router.yaml with mode 0600' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-RouterSeedIsoGeneration -Vm (New-RouterTestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -match `
                    "(?s)path: /etc/netplan/99-router\.yaml.*?permissions: '0600'"
            }
        }

        It 'neutralises the Azure base-image /etc/netplan/90-hotplug-azure.yaml' {
            # The Azure cloud image ships an ephemeral-NIC netplan
            # entry that turns on dhcp4 for every hv_netvsc NIC not
            # named eth0. After our set-name renames the router's
            # NICs to ext0 / priv0 that match wildcard catches both
            # and fights our static config. The seed's write_files
            # overwrites the Azure file with an empty-but-valid
            # netplan v2 document so the merged config has no DHCP
            # fallback racing the static addresses.
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-RouterSeedIsoGeneration -Vm (New-RouterTestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -match (
                    '(?s)path: /etc/netplan/90-hotplug-azure\.yaml\s*\r?\n' +
                    '\s*permissions: ''0600''\s*\r?\n' +
                    '\s*content: \|\s*\r?\n' +
                    '\s*network:\s*\r?\n' +
                    '\s*version: 2'
                )
            }
        }

        It 'configures ext0 and priv0 ethernet entries with set-name' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-RouterSeedIsoGeneration -Vm (New-RouterTestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -match '(?s)ext0:.*?set-name: ext0' -and
                $Files['user-data'] -match '(?s)priv0:.*?set-name: priv0'
            }
        }

        It 'matches each ethernet entry by its deterministic MAC' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            $extMac  = (Get-RouterNicStaticMac -VmName 'router-prod' -Role 'external').Netplan
            $privMac = (Get-RouterNicStaticMac -VmName 'router-prod' -Role 'private').Netplan
            Invoke-RouterSeedIsoGeneration -Vm (New-RouterTestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -match ([regex]::Escape("macaddress: $extMac")) -and
                $Files['user-data'] -match ([regex]::Escape("macaddress: $privMac"))
            }
        }

        It 'configures the external NIC with addresses, default route, and DNS' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-RouterSeedIsoGeneration -Vm (New-RouterTestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -match `
                    '(?s)ext0:.*?- 192\.168\.1\.10/24.*?via: 192\.168\.1\.1.*?- 8\.8\.8\.8'
            }
        }

        It 'emits a DHCP ext0 entry when externalDhcp is true (default)' {
            # Capture the user-data via Mock side-effect rather than
            # asserting in a ParameterFilter scriptblock - the filter
            # runs in Pester's mock-evaluation scope and a regex hiccup
            # there reads as "no matching invocation" rather than a
            # clear assertion failure.
            #
            # The DHCP ext0 stanza is shaped exactly as:
            #     ext0:
            #       match:
            #         macaddress: <pinned>
            #       set-name: ext0
            #       dhcp4: true
            # so `set-name: ext0` immediately followed by `dhcp4: true`
            # is a precise structural signal. Asserting via that pair
            # avoids the cloud-init literal-block indentation tripping
            # any "extract just the ext0 slice" regex.
            Mock Test-Path { $true }
            $script:_capturedUserData = $null
            Mock New-SeedIso {
                $script:_capturedUserData = $Files['user-data']
            }
            Invoke-RouterSeedIsoGeneration -Vm (New-DhcpRouterTestVm)

            $script:_capturedUserData |
                Should -Match 'set-name: ext0\s*\r?\n\s+dhcp4: true'
        }

        It 'omits operator IP / gateway / DNS literals from the ext0 stanza in DHCP mode' {
            # Belt-and-braces regression check distinct from the
            # "emits dhcp4: true" assertion. A future regression that
            # left the static literals in but added dhcp4:true (a
            # half-applied refactor) would fail this even if the
            # previous test happened to pass. Asserts that no line
            # between `set-name: ext0` and the next set-name (priv0)
            # carries an addresses / routes / nameservers block. The
            # match runs across the whole user-data and uses a
            # lookahead bounded by the next set-name token, which is
            # robust to literal-block indentation.
            Mock Test-Path { $true }
            $script:_capturedUserData = $null
            Mock New-SeedIso {
                $script:_capturedUserData = $Files['user-data']
            }
            Invoke-RouterSeedIsoGeneration -Vm (New-DhcpRouterTestVm)

            $script:_capturedUserData |
                Should -Not -Match (
                    '(?s)set-name: ext0\s*\r?\n' +
                    '(?:(?!set-name:).)*?(?:addresses:|routes:|nameservers:)'
                )
        }

        It 'configures the private NIC with the privateIpAddress and no gateway' {
            # The private NIC IS the downstream gateway. Adding an
            # upstream gateway here would create a routing loop.
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-RouterSeedIsoGeneration -Vm (New-RouterTestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                # priv0 block has the address but no routes: line.
                $userData = $Files['user-data']
                if ($userData -notmatch '(?s)priv0:.*?- 10\.10\.0\.1/24') { return $false }
                # Extract the priv0 block: from 'priv0:' to next ethernet
                # entry boundary (end of ethernets section) or end of file.
                $block = [regex]::Match($userData,
                    '(?s)priv0:.*?(?=\n(?: {4}\w+:|[A-Za-z]|$))').Value
                $block -notmatch '(?m)^\s*routes:'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'user-data runcmd order' {
    # ------------------------------------------------------------------
        # netplan apply first - bind both NICs so dnsmasq's
        # listen-address has an interface IP to attach to even when
        # init-local did not apply the seed's network-config (Azure
        # base-image netplan defaults can shadow it). Then sysctl
        # before nftables (forwarding must be on before traffic is
        # matched), nftables before dnsmasq. systemctl daemon-reload
        # sits between nftables and dnsmasq so systemd picks up
        # dnsmasq's drop-in (Context "user-data dnsmasq drop-in"
        # above) before `enable --now dnsmasq.service` starts the
        # unit for the first time.

        It 'orders runcmd: diag -> netplan -> diag -> sysctl -> wait-dns -> apt -> nftables -> reload -> dnsmasq' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-RouterSeedIsoGeneration -Vm (New-RouterTestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -match (
                    '(?s)runcmd:\s*\r?\n' +
                    '\s*-\s*sh -c "echo ''--- \[diag\] /etc/netplan/.+?"\s*\r?\n' +
                    '\s*-\s*netplan apply\s*\r?\n' +
                    '\s*-\s*sh -c "echo ''--- \[diag\] networkctl.+?"\s*\r?\n' +
                    '\s*-\s*sysctl --system\s*\r?\n' +
                    '\s*-\s*timeout 120 sh -c ''until getent hosts archive\.ubuntu\.com.+?''\s*\r?\n' +
                    '\s*-\s*apt-get update\s*\r?\n' +
                    '\s*-\s*DEBIAN_FRONTEND=noninteractive apt-get install -y nftables dnsmasq\s*\r?\n' +
                    '\s*-\s*systemctl enable --now nftables\.service\s*\r?\n' +
                    '\s*-\s*systemctl daemon-reload\s*\r?\n' +
                    '\s*-\s*systemctl enable --now dnsmasq\.service'
                )
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'cloud-init disable flag (subsequent boots)' {
    # ------------------------------------------------------------------

        It 'writes the disable flag at /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-RouterSeedIsoGeneration -Vm (New-RouterTestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -match `
                    'path: /etc/cloud/cloud\.cfg\.d/99-disable-network-config\.cfg'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'ISO file structure' {
    # ------------------------------------------------------------------

        It 'passes meta-data, user-data, and network-config to New-SeedIso' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-RouterSeedIsoGeneration -Vm (New-RouterTestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files.Keys.Count -eq 3              -and
                $Files.ContainsKey('meta-data')      -and
                $Files.ContainsKey('user-data')      -and
                $Files.ContainsKey('network-config')
            }
        }

        It 'ships network-config equal to the netplan embedded in user-data' {
            # First-boot bring-up (network-config -> 50-cloud-init.yaml)
            # and on-disk owner (write_files -> 99-router.yaml) must use
            # the same source so they cannot drift.
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-RouterSeedIsoGeneration -Vm (New-RouterTestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $netConfig = $Files['network-config']
                $userData  = $Files['user-data']
                # The netplan block in user-data is indented six spaces;
                # strip that to compare with the raw network-config.
                $netConfig -match 'ext0:' -and
                $netConfig -match 'priv0:' -and
                $userData.Contains((($netConfig -split "`r?`n" |
                    ForEach-Object { "      $_" }) -join "`n"))
            }
        }

        It 'writes the ISO to vmConfigPath/{vmName}-seed.iso' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-RouterSeedIsoGeneration -Vm (New-RouterTestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $OutputPath -eq 'C:\a_VMs\Hyper-V\Config\router-prod-seed.iso'
            }
        }
    }

    # ------------------------------------------------------------------
    Context '_seedIsoPath output' {
    # ------------------------------------------------------------------

        It 'sets _seedIsoPath on the VM object after writing the ISO' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            $vm = New-RouterTestVm
            Invoke-RouterSeedIsoGeneration -Vm $vm
            $vm._seedIsoPath | Should -Be 'C:\a_VMs\Hyper-V\Config\router-prod-seed.iso'
        }
    }
}
