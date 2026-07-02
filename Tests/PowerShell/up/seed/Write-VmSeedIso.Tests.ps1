BeforeAll {
    # New-SeedIso depends on IMAPI2 COM objects unavailable in a headless
    # test environment - stub before dot-sourcing so the function reference
    # resolves.
    function New-SeedIso { param($OutputPath, $Files) }

    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\up\seed\Write-VmSeedIso.ps1"

    function New-TestVm {
        [PSCustomObject]@{
            vmName       = 'node-01'
            vmConfigPath = 'C:\a_VMs\Hyper-V\Config'
        }
    }
}

Describe 'Write-VmSeedIso' {

    # ------------------------------------------------------------------
    Context 'output path composition' {
    # ------------------------------------------------------------------

        It 'writes the ISO to vmConfigPath/{vmName}-seed.iso' {
            Mock New-SeedIso {}
            Write-VmSeedIso -Vm (New-TestVm) `
                            -MetaData 'm' -UserData 'u' -NetworkConfig 'n'
            Should -Invoke New-SeedIso -Times 1 -Exactly -ParameterFilter {
                $OutputPath -eq 'C:\a_VMs\Hyper-V\Config\node-01-seed.iso'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'New-SeedIso payload' {
    # ------------------------------------------------------------------

        It 'passes meta-data, user-data, and network-config under their NoCloud keys' {
            Mock New-SeedIso {}
            Write-VmSeedIso -Vm (New-TestVm) `
                            -MetaData 'M' -UserData 'U' -NetworkConfig 'N'
            Should -Invoke New-SeedIso -Times 1 -Exactly -ParameterFilter {
                $Files.Keys.Count -eq 3                  -and
                $Files['meta-data']      -eq 'M'         -and
                $Files['user-data']      -eq 'U'         -and
                $Files['network-config'] -eq 'N'
            }
        }
    }

    # ------------------------------------------------------------------
    Context '_seedIsoPath note property' {
    # ------------------------------------------------------------------

        It 'sets _seedIsoPath on the VM object after writing the ISO' {
            Mock New-SeedIso {}
            $vm = New-TestVm
            Write-VmSeedIso -Vm $vm -MetaData 'm' -UserData 'u' -NetworkConfig 'n'
            $vm._seedIsoPath | Should -Be 'C:\a_VMs\Hyper-V\Config\node-01-seed.iso'
        }

        It 'overwrites an existing _seedIsoPath rather than throwing' {
            # Re-running on a VM object that already carries a stale
            # _seedIsoPath (e.g. a retry after a transient failure) must
            # not fail with "property already exists".
            Mock New-SeedIso {}
            $vm = New-TestVm
            $vm | Add-Member -MemberType NoteProperty `
                  -Name '_seedIsoPath' -Value 'C:\old\path'
            Write-VmSeedIso -Vm $vm -MetaData 'm' -UserData 'u' -NetworkConfig 'n'
            $vm._seedIsoPath | Should -Be 'C:\a_VMs\Hyper-V\Config\node-01-seed.iso'
        }
    }
}
