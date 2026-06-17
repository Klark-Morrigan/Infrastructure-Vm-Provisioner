BeforeAll {
    # Stub all Hyper-V and filesystem cmdlets unavailable outside a Hyper-V host.
    function Get-VM        { param($Name, [switch]$ErrorAction) }
    function Stop-VM       { param($Name, [switch]$Force) }
    function Remove-VM     { param($Name, [switch]$Force) }
    function Remove-Item   { param($Path, [switch]$Recurse, [switch]$Force, $ErrorAction) }
    function Test-Path     { param($Path) }

    # remove-vm.ps1 wraps file deletions in Invoke-WithRetry (from
    # Common.PowerShell) with the file-lock retry strategy. Stub both
    # as pass-throughs so these tests focus on Invoke-VmRemoval's
    # orchestration; the retry loop itself is covered by
    # Invoke-WithRetry.Tests.ps1 in Common.PowerShell.
    function Invoke-WithRetry {
        param([scriptblock] $ScriptBlock, [hashtable[]] $RetryStrategy,
              [hashtable] $BackoffStrategy, [int] $MaxAttempts,
              [string] $OperationName)
        return & $ScriptBlock
    }
    function New-FileLockRetryStrategy {
        return @{ Name = 'FileLock'; ShouldRetry = { $false } }
    }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\down\vm\remove-vm.ps1"

    # Standard VM object satisfying all Invoke-VmRemoval requirements.
    function New-TestVm {
        [PSCustomObject]@{
            vmName       = 'node-01'
            vhdPath      = 'C:\a_VMs\Hyper-V\Disks'
            vmConfigPath = 'C:\a_VMs\Hyper-V\Config'
        }
    }

    # Sets up all stubs in their neutral no-op form.
    function Initialize-Mocks {
        Mock Get-VM           { [PSCustomObject]@{ State = 'Off' } }
        Mock Stop-VM          { }
        Mock Remove-VM        { }
        Mock Test-Path        { $false }
        Mock Remove-Item      { }
        Mock Invoke-WithRetry { param([scriptblock] $ScriptBlock) & $ScriptBlock }
        Mock New-FileLockRetryStrategy {
            @{ Name = 'FileLock'; ShouldRetry = { $false } }
        }
    }
}

Describe 'Invoke-VmRemoval' {

    # ------------------------------------------------------------------
    Context 'Hyper-V teardown - VM present' {
    # ------------------------------------------------------------------

        It 'calls Stop-VM when the VM is in a running state' {
            Initialize-Mocks
            Mock Get-VM { [PSCustomObject]@{ State = 'Running' } }

            Invoke-VmRemoval -Vm (New-TestVm)

            # -Force prevents an interactive confirmation prompt that would
            # block CI when the VM is running.
            Should -Invoke Stop-VM -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'node-01' -and $Force -eq $true
            }
        }

        It 'does not call Stop-VM when the VM is already Off' {
            Initialize-Mocks
            Mock Get-VM { [PSCustomObject]@{ State = 'Off' } }

            Invoke-VmRemoval -Vm (New-TestVm)

            Should -Invoke Stop-VM -Times 0
        }

        It 'calls Remove-VM when the VM is Off' {
            Initialize-Mocks

            Invoke-VmRemoval -Vm (New-TestVm)

            # -Force prevents an interactive confirmation prompt that would
            # block CI.
            Should -Invoke Remove-VM -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'node-01' -and $Force -eq $true
            }
        }

        It 'calls Remove-VM after Stop-VM when the VM is Running' {
            Initialize-Mocks
            Mock Get-VM { [PSCustomObject]@{ State = 'Running' } }

            Invoke-VmRemoval -Vm (New-TestVm)

            Should -Invoke Remove-VM -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'node-01' -and $Force -eq $true
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'Hyper-V teardown - VM absent' {
    # ------------------------------------------------------------------
        # If a prior run removed the VM but file cleanup did not complete,
        # re-running must still proceed to file deletion.

        It 'skips Stop-VM and Remove-VM when the VM is absent from Hyper-V' {
            Initialize-Mocks
            Mock Get-VM { $null }

            Invoke-VmRemoval -Vm (New-TestVm)

            Should -Invoke Stop-VM  -Times 0
            Should -Invoke Remove-VM -Times 0
        }

        It 'still deletes the VHDX when the VM is absent from Hyper-V' {
            Initialize-Mocks
            Mock Get-VM    { $null }
            Mock Test-Path { $true }

            Invoke-VmRemoval -Vm (New-TestVm)

            Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter {
                $Path -like '*node-01.vhdx'
            }
        }

        It 'still deletes the seed ISO and config dir when the VM is absent from Hyper-V' {
            Initialize-Mocks
            Mock Get-VM    { $null }
            Mock Test-Path { $true }

            Invoke-VmRemoval -Vm (New-TestVm)

            Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter {
                $Path -like '*node-01-seed.iso'
            }
            Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter {
                $Path -like '*Config\node-01'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'VHDX deletion' {
    # ------------------------------------------------------------------

        It 'deletes the VHDX when it exists' {
            Initialize-Mocks
            Mock Test-Path { param($Path) $Path -like '*node-01.vhdx' }

            Invoke-VmRemoval -Vm (New-TestVm)

            Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter {
                $Path -like '*node-01.vhdx'
            }
        }

        It 'does not throw when the VHDX is absent' {
            Initialize-Mocks
            Mock Test-Path { $false }

            { Invoke-VmRemoval -Vm (New-TestVm) } | Should -Not -Throw
        }

        It 'wraps VHDX deletion in Invoke-WithRetry with the FileLock strategy and MaxAttempts 5' {
            # The retry loop itself is covered by Invoke-WithRetry.Tests.ps1
            # in Common.PowerShell; here we only assert the call site
            # plumbs the right strategy and attempt budget.
            Initialize-Mocks
            Mock Test-Path { param($Path) $Path -like '*node-01.vhdx' }

            Invoke-VmRemoval -Vm (New-TestVm)

            Should -Invoke Invoke-WithRetry -Times 1 -Exactly -ParameterFilter {
                $MaxAttempts -eq 5 -and
                $RetryStrategy.Count -eq 1 -and
                $RetryStrategy[0].Name -eq 'FileLock' -and
                $OperationName -like '*node-01.vhdx*'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'seed ISO deletion' {
    # ------------------------------------------------------------------

        It 'deletes the seed ISO when it exists' {
            Initialize-Mocks
            Mock Test-Path { param($Path) $Path -like '*node-01-seed.iso' }

            Invoke-VmRemoval -Vm (New-TestVm)

            Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter {
                $Path -like '*node-01-seed.iso' -and $Force -eq $true
            }
        }

        It 'does not throw when the seed ISO is absent' {
            Initialize-Mocks
            Mock Test-Path { $false }

            { Invoke-VmRemoval -Vm (New-TestVm) } | Should -Not -Throw
        }

        It 'does not wrap seed ISO deletion in Invoke-WithRetry' {
            # Seed ISOs are not held by VMMS - retry would only mask real
            # errors. Asserting absence guards against accidental
            # generalisation of the retry policy.
            Initialize-Mocks
            Mock Test-Path { param($Path) $Path -like '*node-01-seed.iso' }

            Invoke-VmRemoval -Vm (New-TestVm)

            Should -Invoke Invoke-WithRetry -Times 0
        }
    }

    # ------------------------------------------------------------------
    Context 'VM config directory deletion' {
    # ------------------------------------------------------------------

        It 'deletes the VM config directory when it exists' {
            Initialize-Mocks
            Mock Test-Path { param($Path) $Path -like '*Config\node-01' }

            Invoke-VmRemoval -Vm (New-TestVm)

            Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter {
                $Path -like '*Config\node-01'
            }
        }

        It 'does not throw when the VM config directory is absent' {
            Initialize-Mocks
            Mock Test-Path { $false }

            { Invoke-VmRemoval -Vm (New-TestVm) } | Should -Not -Throw
        }

        It 'wraps config directory deletion in Invoke-WithRetry with the FileLock strategy and MaxAttempts 5' {
            Initialize-Mocks
            Mock Test-Path { param($Path) $Path -like '*Config\node-01' }

            Invoke-VmRemoval -Vm (New-TestVm)

            Should -Invoke Invoke-WithRetry -Times 1 -Exactly -ParameterFilter {
                $MaxAttempts -eq 5 -and
                $RetryStrategy.Count -eq 1 -and
                $RetryStrategy[0].Name -eq 'FileLock' -and
                $OperationName -like '*Config\node-01*'
            }
        }
    }
}
