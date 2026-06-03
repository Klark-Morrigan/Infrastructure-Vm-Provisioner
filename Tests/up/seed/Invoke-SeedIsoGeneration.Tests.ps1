BeforeAll {
    # New-SeedIso lives in iso.ps1 and depends on IMAPI2 COM objects that are
    # unavailable in a headless test environment. Stub it before dot-sourcing
    # generate-seed-iso.ps1 so the function reference resolves without error.
    function New-SeedIso { param($OutputPath, $Files) }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\seed\New-StaticNetplanYaml.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\seed\generate-seed-iso.ps1"

    function New-TestVm {
        [PSCustomObject]@{
            vmName       = 'node-01'
            vmConfigPath = 'C:\a_VMs\Hyper-V\Config'
            username     = 'admin'
            password     = 'P@ssw0rd'
            ipAddress    = '192.168.1.10'
            subnetMask   = '24'
            gateway      = '192.168.1.1'
            dns          = '8.8.8.8'
        }
    }
}

Describe 'Invoke-SeedIsoGeneration' {

    # ------------------------------------------------------------------
    Context 'vmConfigPath setup' {
    # ------------------------------------------------------------------

        It 'creates vmConfigPath directory when it does not exist' {
            Mock Test-Path { $false }
            Mock New-Item {}
            Mock New-SeedIso {}
            Invoke-SeedIsoGeneration -Vm (New-TestVm)
            Should -Invoke New-Item -Times 1 -Exactly -ParameterFilter {
                $ItemType -eq 'Directory' -and $Path -eq 'C:\a_VMs\Hyper-V\Config'
            }
        }

        It 'does not create vmConfigPath when it already exists' {
            Mock Test-Path { $true }
            Mock New-Item {}
            Mock New-SeedIso {}
            Invoke-SeedIsoGeneration -Vm (New-TestVm)
            Should -Invoke New-Item -Times 0
        }
    }

    # ------------------------------------------------------------------
    Context 'meta-data content' {
    # ------------------------------------------------------------------

        It 'sets instance-id to vmName' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-SeedIsoGeneration -Vm (New-TestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['meta-data'] -match 'instance-id: node-01'
            }
        }

        It 'sets local-hostname to vmName' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-SeedIsoGeneration -Vm (New-TestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['meta-data'] -match 'local-hostname: node-01'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'user-data content' {
    # ------------------------------------------------------------------

        It 'includes the configured username' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-SeedIsoGeneration -Vm (New-TestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -match 'name: "admin"'
            }
        }

        It 'includes the configured password' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-SeedIsoGeneration -Vm (New-TestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -match 'plain_text_passwd: "P@ssw0rd"'
            }
        }

        It 'escapes backslashes in username for YAML double-quoted strings' {
            # A domain\user credential would break YAML without escaping the
            # backslash. The -replace '\\', '\\\\' in the source doubles it.
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            $vm = [PSCustomObject]@{
                vmName       = 'node-01'
                vmConfigPath = 'C:\a_VMs\Hyper-V\Config'
                username     = 'domain\admin'
                password     = 'P@ssw0rd'
                ipAddress    = '192.168.1.10'
                subnetMask   = '24'
                gateway      = '192.168.1.1'
                dns          = '8.8.8.8'
            }
            Invoke-SeedIsoGeneration -Vm $vm
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -match ([regex]::Escape('name: "domain\\admin"'))
            }
        }

        It 'escapes double quotes in password for YAML double-quoted strings' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            $vm = [PSCustomObject]@{
                vmName       = 'node-01'
                vmConfigPath = 'C:\a_VMs\Hyper-V\Config'
                username     = 'admin'
                password     = 'P@ss"word'
                ipAddress    = '192.168.1.10'
                subnetMask   = '24'
                gateway      = '192.168.1.1'
                dns          = '8.8.8.8'
            }
            Invoke-SeedIsoGeneration -Vm $vm
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -match ([regex]::Escape('plain_text_passwd: "P@ss\"word"'))
            }
        }

        It 'sets ssh_pwauth to true' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-SeedIsoGeneration -Vm (New-TestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -match 'ssh_pwauth: true'
            }
        }

        It 'omits packages / package_update / package_upgrade so cloud-init does not need internet' {
            # openssh-server is already in the Ubuntu cloud image (see
            # Invoke-BaseImagePatch.ps1 Patch 2) and we install no other
            # packages. Emitting any of these keys re-activates the
            # cc_package_update_upgrade_install module, which runs
            # apt-get update against Ubuntu mirrors - DNS resolution
            # there fails when the host NAT does not cover the VM
            # subnet, and apt waits its full retry budget (~6 minutes)
            # before falling back to cached lists.
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-SeedIsoGeneration -Vm (New-TestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -notmatch '(?m)^packages:'        -and
                $Files['user-data'] -notmatch '(?m)^package_update:'  -and
                $Files['user-data'] -notmatch '(?m)^package_upgrade:'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'user-data write_files for static networking' {
    # ------------------------------------------------------------------
    # These entries are what makes netplan - not cloud-init - the owner
    # of /etc/netplan/99-static.yaml on every boot after the first. See
    # problem.md (40 - static network config).

        It 'declares a write_files block in user-data' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-SeedIsoGeneration -Vm (New-TestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -match '(?m)^write_files:'
            }
        }

        It 'writes the cloud-init network disable flag at the expected path' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-SeedIsoGeneration -Vm (New-TestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -match `
                    'path: /etc/cloud/cloud\.cfg\.d/99-disable-network-config\.cfg'
            }
        }

        It 'writes the disable flag content exactly as cloud-init parses it verbatim' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-SeedIsoGeneration -Vm (New-TestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -match `
                    ([regex]::Escape("content: 'network: {config: disabled}'"))
            }
        }

        It 'writes the disable flag with mode 0644' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-SeedIsoGeneration -Vm (New-TestVm)
            # The disable flag block comes first; assert the 0644 line
            # appears between its path and the next path entry.
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -match `
                    "(?s)99-disable-network-config\.cfg.*?permissions: '0644'.*?99-static\.yaml"
            }
        }

        It 'writes the static netplan at /etc/netplan/99-static.yaml' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-SeedIsoGeneration -Vm (New-TestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -match 'path: /etc/netplan/99-static\.yaml'
            }
        }

        It 'writes the static netplan with mode 0600' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-SeedIsoGeneration -Vm (New-TestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -match `
                    "(?s)99-static\.yaml.*?permissions: '0600'"
            }
        }

        It 'embeds the New-StaticNetplanYaml output verbatim under the netplan write_files entry' {
            # Re-derive the expected YAML the same way the source does
            # (same Vm config -> same template output) and assert each
            # line lands inside user-data indented by six spaces.
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            $vm       = New-TestVm
            $expected = New-StaticNetplanYaml `
                -IpAddress  $vm.ipAddress `
                -SubnetMask $vm.subnetMask `
                -Gateway    $vm.gateway `
                -Dns        $vm.dns
            $expectedIndented = ($expected -split "`r?`n" |
                ForEach-Object { "      $_" }) -join "`n"
            Invoke-SeedIsoGeneration -Vm $vm
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'].Contains($expectedIndented)
            }
        }

        It 'runs netplan apply via runcmd so the static IP is live during first boot' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-SeedIsoGeneration -Vm (New-TestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -match "(?m)^runcmd:\s*`r?`n\s*-\s*netplan apply\s*$"
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'ISO file structure' {
    # ------------------------------------------------------------------

        It 'passes meta-data, user-data, and network-config to New-SeedIso' {
            # network-config carries the disable flag. cloud-init reads it
            # in the init stage (BEFORE write_files), so it is the only
            # place the flag can land in time to prevent first-boot DHCP
            # fallback. See generate-seed-iso.ps1 file header.
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-SeedIsoGeneration -Vm (New-TestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files.Keys.Count -eq 3              -and
                $Files.ContainsKey('meta-data')      -and
                $Files.ContainsKey('user-data')      -and
                $Files.ContainsKey('network-config')
            }
        }

        It 'ships network-config equal to New-StaticNetplanYaml output' {
            # Same template as the write_files entry, so first-boot
            # (network-config -> 50-cloud-init.yaml) and on-disk
            # (write_files -> 99-static.yaml) cannot drift. Cloud-init
            # owns first-boot bring-up via this slot; the write_files
            # disable flag handles subsequent boots.
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            $vm       = New-TestVm
            $expected = New-StaticNetplanYaml `
                -IpAddress  $vm.ipAddress `
                -SubnetMask $vm.subnetMask `
                -Gateway    $vm.gateway `
                -Dns        $vm.dns
            Invoke-SeedIsoGeneration -Vm $vm
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['network-config'] -eq $expected
            }
        }

        It 'writes the ISO to vmConfigPath/{vmName}-seed.iso' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-SeedIsoGeneration -Vm (New-TestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $OutputPath -eq 'C:\a_VMs\Hyper-V\Config\node-01-seed.iso'
            }
        }
    }

    # ------------------------------------------------------------------
    Context '_seedIsoPath output' {
    # ------------------------------------------------------------------

        It 'sets _seedIsoPath on the VM object after writing the ISO' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            $vm = New-TestVm
            Invoke-SeedIsoGeneration -Vm $vm
            $vm._seedIsoPath | Should -Be 'C:\a_VMs\Hyper-V\Config\node-01-seed.iso'
        }
    }
}
