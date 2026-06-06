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

    # Standard router VM definition. Fixture content (router-nftables.conf,
    # router-dnsmasq.conf) is keyed to these values - changing them here
    # without updating the fixtures will fail the string-equal checks.
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
            externalSwitchName  = 'ExtSwitch'
            privateSwitchName   = 'PrivSwitch-prod'
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
    Context 'user-data packages' {
    # ------------------------------------------------------------------

        It 'declares a packages: block listing nftables and dnsmasq' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-RouterSeedIsoGeneration -Vm (New-RouterTestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -match '(?ms)^packages:\s*\r?\n\s*-\s*nftables\s*\r?\n\s*-\s*dnsmasq'
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
        # sysctl before nftables (forwarding must be on before traffic
        # is matched), nftables before dnsmasq (so dnsmasq binds after
        # the ruleset is up), netplan apply last (belt-and-braces
        # against init-local already having applied network-config).

        It 'orders runcmd entries as sysctl -> nftables -> dnsmasq -> netplan' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-RouterSeedIsoGeneration -Vm (New-RouterTestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -match (
                    '(?s)runcmd:\s*\r?\n' +
                    '\s*-\s*sysctl --system\s*\r?\n' +
                    '\s*-\s*systemctl enable --now nftables\.service\s*\r?\n' +
                    '\s*-\s*systemctl enable --now dnsmasq\.service\s*\r?\n' +
                    '\s*-\s*netplan apply'
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
