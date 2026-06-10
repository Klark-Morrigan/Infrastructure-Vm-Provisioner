BeforeAll {
    # Stub Hyper-V cmdlets unavailable outside a Hyper-V host.
    function Get-VMDvdDrive    { param($VMName) }
    function Remove-VMDvdDrive { param($VMName, $ControllerNumber, $ControllerLocation) }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\vm\Remove-VmSeedIso.ps1"
}

Describe 'Remove-VmSeedIso' {

    Context 'DVD drive attached AND ISO file present' {

        It 'detaches the matching DVD drive THEN deletes the ISO' {
            $script:_callOrder = @()
            Mock Get-VMDvdDrive {
                $script:_callOrder += 'Get-VMDvdDrive'
                @(
                    [PSCustomObject]@{
                        Path               = 'C:\seed-other.iso'
                        ControllerNumber   = 0
                        ControllerLocation = 1
                    },
                    [PSCustomObject]@{
                        Path               = 'C:\seed.iso'
                        ControllerNumber   = 0
                        ControllerLocation = 2
                    }
                )
            }
            Mock Remove-VMDvdDrive { $script:_callOrder += 'Remove-VMDvdDrive' }
            Mock Test-Path         { $script:_callOrder += 'Test-Path'; $true }
            Mock Remove-Item       { $script:_callOrder += 'Remove-Item' }

            Remove-VmSeedIso -VmName 'vm-01' -SeedIsoPath 'C:\seed.iso'

            # Ordering is load-bearing - detach must precede file delete.
            $script:_callOrder | Should -Be @(
                'Get-VMDvdDrive','Remove-VMDvdDrive','Test-Path','Remove-Item')
        }

        It 'matches the DVD drive by Path, not by index or VM name' {
            # Regression guard: the seed ISO might not be the first
            # DVD drive on the VM. Match must be by Path equality.
            Mock Get-VMDvdDrive {
                @(
                    [PSCustomObject]@{
                        Path               = 'C:\other.iso'
                        ControllerNumber   = 0
                        ControllerLocation = 1
                    },
                    [PSCustomObject]@{
                        Path               = 'C:\seed.iso'
                        ControllerNumber   = 1
                        ControllerLocation = 5
                    }
                )
            }
            Mock Remove-VMDvdDrive { }
            Mock Test-Path   { $true }
            Mock Remove-Item { }

            Remove-VmSeedIso -VmName 'vm-01' -SeedIsoPath 'C:\seed.iso'

            Should -Invoke Remove-VMDvdDrive -Times 1 -Exactly -ParameterFilter {
                $ControllerNumber -eq 1 -and $ControllerLocation -eq 5
            }
        }
    }

    Context 'idempotency - DVD drive absent' {

        It 'skips Remove-VMDvdDrive when no DVD drive Path matches' {
            # No DVD drive on the VM has the seed-ISO path. Could be a
            # prior run already detached it, or the VM never had it
            # attached. Either way, calling Remove-VMDvdDrive would
            # null-ref on the missing $dvdDrive object.
            Mock Get-VMDvdDrive    { @() }
            Mock Remove-VMDvdDrive { }
            Mock Test-Path         { $false }
            Mock Remove-Item       { }

            { Remove-VmSeedIso -VmName 'vm-01' -SeedIsoPath 'C:\seed.iso' } |
                Should -Not -Throw

            Should -Invoke Remove-VMDvdDrive -Times 0 -Exactly
        }
    }

    Context 'idempotency - ISO file absent' {

        It 'skips Remove-Item when the ISO file is not on disk' {
            # File was deleted by an earlier run or never written.
            # Remove-Item on a missing path with -Force would still
            # succeed silently, but skipping it keeps the "[OK] Seed
            # ISO removed." message out of the operator output when
            # nothing was actually removed.
            Mock Get-VMDvdDrive    { @() }
            Mock Remove-VMDvdDrive { }
            Mock Test-Path         { $false }
            $script:_removeItemCalls = 0
            Mock Remove-Item { $script:_removeItemCalls++ }

            Remove-VmSeedIso -VmName 'vm-01' -SeedIsoPath 'C:\seed.iso'

            $script:_removeItemCalls | Should -Be 0
        }
    }

    Context 'partial state - DVD detached but ISO file lingers' {

        It 'still deletes the lingering ISO file' {
            # Last run detached the DVD but crashed before deleting
            # the ISO. The seed contains the plaintext admin password
            # - leaving it on disk is the security-critical case.
            Mock Get-VMDvdDrive    { @() }
            Mock Remove-VMDvdDrive { }
            Mock Test-Path         { $true }
            Mock Remove-Item       { }

            Remove-VmSeedIso -VmName 'vm-01' -SeedIsoPath 'C:\seed.iso'

            Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter {
                $Path -eq 'C:\seed.iso'
            }
        }
    }
}
