<#
.SYNOPSIS
    Unit tests for Invoke-VmFleetPowerOn.

.DESCRIPTION
    Pins the power-on loop contract:
      - one Start-VmIfStopped call per VM, in input order;
      - successful transitions returned in Transitions, in input order;
      - a single VM throwing is recorded in Failed and never strands the
        rest of the list;
      - both buckets are always arrays (the single-match scalar-unrolling
        trap must not surface to callers doing .Count math);
      - empty input is a no-op (no Start-VmIfStopped call), both buckets
        empty.

    Start-VmIfStopped is the only dependency and is stubbed/mocked here;
    its own behaviour is covered by
    Infrastructure-HyperV/Tests/Start-VmIfStopped.Tests.ps1.
#>

BeforeAll {
    # Stub the single dependency so Pester's Mock can attach by name. The
    # VmName param is declared so ParameterFilter can bind it.
    function Start-VmIfStopped { param([string] $VmName) }

    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\common\power\Invoke-VmFleetPowerOn.ps1"

    function New-VmDefs {
        param([string[]] $Names)
        ,@($Names | ForEach-Object { [PSCustomObject]@{ vmName = $_ } })
    }
}

Describe 'Invoke-VmFleetPowerOn' {

    Context 'three VMs, one of each transition' {

        BeforeEach {
            Mock Start-VmIfStopped {
                param([string] $VmName)
                switch ($VmName) {
                    'vm-a' { [PSCustomObject]@{ VmName='vm-a'; EntryState='Off';     Action='Started'        } }
                    'vm-b' { [PSCustomObject]@{ VmName='vm-b'; EntryState='Saved';   Action='Resumed'        } }
                    'vm-c' { [PSCustomObject]@{ VmName='vm-c'; EntryState='Running'; Action='AlreadyRunning' } }
                }
            }
            $script:result = Invoke-VmFleetPowerOn -VmDefs (New-VmDefs 'vm-a','vm-b','vm-c')
        }

        It 'calls Start-VmIfStopped exactly once per VM' {
            Should -Invoke Start-VmIfStopped -Times 3 -Exactly
        }

        It 'calls Start-VmIfStopped with each VmName' {
            foreach ($name in 'vm-a','vm-b','vm-c') {
                Should -Invoke Start-VmIfStopped -Times 1 -Exactly `
                    -ParameterFilter { $VmName -eq $name }
            }
        }

        It 'returns the three transitions in input order' {
            $script:result.Transitions.Count | Should -Be 3
            $script:result.Transitions[0].VmName | Should -Be 'vm-a'
            $script:result.Transitions[1].VmName | Should -Be 'vm-b'
            $script:result.Transitions[2].VmName | Should -Be 'vm-c'
        }

        It 'returns an empty Failed bucket' {
            @($script:result.Failed).Count | Should -Be 0
        }
    }

    Context 'one VM throws - the rest of the list is not stranded' {

        BeforeEach {
            Mock Start-VmIfStopped {
                param([string] $VmName)
                if ($VmName -eq 'vm-b') {
                    throw "VM 'vm-b' is in transient/unsupported state 'Paused'; refusing to call Start-VM."
                }
                [PSCustomObject]@{ VmName=$VmName; EntryState='Off'; Action='Started' }
            }
            $script:result = Invoke-VmFleetPowerOn `
                -VmDefs (New-VmDefs 'vm-a','vm-b','vm-c','vm-d')
        }

        It 'still attempts every VM after the failing one' {
            Should -Invoke Start-VmIfStopped -Times 4 -Exactly
        }

        It 'records the failure with the original exception message' {
            @($script:result.Failed).Count | Should -Be 1
            $script:result.Failed[0].VmName | Should -Be 'vm-b'
            $script:result.Failed[0].Reason | Should -Match "transient/unsupported state 'Paused'"
        }

        It 'keeps the successful transitions' {
            $script:result.Transitions.Count | Should -Be 3
            @($script:result.Transitions | ForEach-Object { $_.VmName }) |
                Should -Be @('vm-a','vm-c','vm-d')
        }
    }

    Context 'every VM throws' {

        BeforeEach {
            Mock Start-VmIfStopped {
                param([string] $VmName)
                throw "boom-$VmName"
            }
            $script:result = Invoke-VmFleetPowerOn -VmDefs (New-VmDefs 'vm-a','vm-b')
        }

        It 'returns an empty Transitions bucket' {
            @($script:result.Transitions).Count | Should -Be 0
        }

        It 'records every VM in Failed with its reason' {
            @($script:result.Failed).Count | Should -Be 2
            $script:result.Failed[0].VmName | Should -Be 'vm-a'
            $script:result.Failed[0].Reason | Should -Be 'boom-vm-a'
            $script:result.Failed[1].VmName | Should -Be 'vm-b'
            $script:result.Failed[1].Reason | Should -Be 'boom-vm-b'
        }
    }

    Context 'single-VM input still returns arrays (strict-mode unrolling guard)' {

        # A dropped @() wrapper or a bare return would unroll a single
        # element to a scalar, and the caller's $result.Failed.Count would
        # throw under strict mode. Both buckets must stay arrays regardless
        # of element count.
        It 'returns a one-element Transitions array on a single success' {
            Mock Start-VmIfStopped {
                [PSCustomObject]@{ VmName='vm-only'; EntryState='Off'; Action='Started' }
            }
            $result = Invoke-VmFleetPowerOn -VmDefs (New-VmDefs 'vm-only')

            $result.Transitions -is [array] | Should -BeTrue
            $result.Failed -is [array]      | Should -BeTrue
            $result.Transitions.Count | Should -Be 1
            $result.Failed.Count      | Should -Be 0
        }

        It 'returns a one-element Failed array on a single failure' {
            Mock Start-VmIfStopped { throw 'boom-vm-only' }
            $result = Invoke-VmFleetPowerOn -VmDefs (New-VmDefs 'vm-only')

            $result.Transitions -is [array] | Should -BeTrue
            $result.Failed -is [array]      | Should -BeTrue
            $result.Transitions.Count | Should -Be 0
            $result.Failed.Count      | Should -Be 1
        }
    }

    Context 'empty -VmDefs' {

        It 'returns both buckets empty and never calls Start-VmIfStopped' {
            Mock Start-VmIfStopped { }
            $result = Invoke-VmFleetPowerOn -VmDefs @()

            @($result.Transitions).Count | Should -Be 0
            @($result.Failed).Count      | Should -Be 0
            Should -Invoke Start-VmIfStopped -Times 0 -Exactly
        }
    }
}
