BeforeAll {
    # Stub Hyper-V cmdlet unavailable outside a Hyper-V host.
    function Get-VM { param($Name, $ErrorAction) }

    # Select-VmsForProvisioning dot-sources Assert-EnvironmentConsistency,
    # which in turn calls Group-VmsByEnvironment. Pull in the real helper
    # so the preflight runs cleanly against test fixtures; behaviour of
    # the preflight rules themselves is covered in
    # Tests/up/config/Assert-EnvironmentConsistency.Tests.ps1.
    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\common\config\Group-VmsByEnvironment.ps1"
    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\up\config\Select-VmsForProvisioning.ps1"

    # Builds a workload VM definition rich enough for the per-environment
    # preflight that runs at the top of Select-VmsForProvisioning. Defaults
    # describe a coherent single-environment batch; tests override fields
    # to exercise specific preflight rules.
    function New-TestVm {
        param(
            [string] $VmName            = 'node-01',
            [string] $IpAddress         = '192.168.1.10',
            [string] $Gateway           = '10.10.0.1',
            [string] $SubnetMask        = '24',
            [string] $PrivateSwitchName = 'PrivateSwitch-Production',
            [string] $Kind              = 'workload'
        )
        [PSCustomObject]@{
            vmName            = $VmName
            ipAddress         = $IpAddress
            gateway           = $Gateway
            subnetMask        = $SubnetMask
            privateSwitchName = $PrivateSwitchName
            kind              = $Kind
        }
    }

    # Builds a router VM definition for the same default environment.
    # privateIpAddress matches the workload's gateway so the env passes
    # the consistency preflight unless the test overrides it.
    #
    # `externalDhcp` defaults to $false here (matching the schema default,
    # static) so the fixture has a known ext0 IP and the IP-conflict /
    # offline-VM Contexts below actually exercise their respective
    # branches. Tests that care about the DHCP-router classification path
    # set ExternalDhcp to $true explicitly - DHCP is now an opt-in that
    # skips Test-IpAddressInUse entirely.
    function New-RouterVm {
        param(
            [string] $VmName            = 'router-prod',
            [string] $IpAddress         = '192.168.1.2',
            [string] $PrivateIpAddress  = '10.10.0.1',
            [string] $SubnetMask        = '24',
            [string] $PrivateSwitchName = 'PrivateSwitch-Production',
            [object] $ExternalDhcp      = $false
        )
        $vm = New-TestVm `
                  -VmName            $VmName `
                  -IpAddress         $IpAddress `
                  -Gateway           $PrivateIpAddress `
                  -SubnetMask        $SubnetMask `
                  -PrivateSwitchName $PrivateSwitchName `
                  -Kind              'router'
        $vm | Add-Member -MemberType NoteProperty -Name privateIpAddress `
                          -Value $PrivateIpAddress
        if ($null -ne $ExternalDhcp) {
            $vm | Add-Member -MemberType NoteProperty -Name externalDhcp `
                              -Value $ExternalDhcp
        }
        $vm
    }

    # Default: no existing VM, no IP conflict (i.e. classified as 'new').
    function Initialize-Mocks {
        Mock Get-VM              { $null  }
        Mock Test-IpAddressInUse { $false }
    }
}

Describe 'Select-VmsForProvisioning' {

    # ------------------------------------------------------------------
    Context 'environment consistency preflight wiring' {
    # ------------------------------------------------------------------
        # The preflight rules themselves are covered in
        # Assert-EnvironmentConsistency.Tests.ps1. Here we only pin the
        # wiring: the function is called once, with the VM defs, before
        # any per-VM classification runs (so a rejected batch never
        # reaches Get-VM / Test-IpAddressInUse).

        It 'invokes Assert-EnvironmentConsistency exactly once with the input VMs' {
            Initialize-Mocks
            Mock Assert-EnvironmentConsistency { }
            @(Select-VmsForProvisioning -VmDefs @((New-RouterVm)))
            Should -Invoke Assert-EnvironmentConsistency -Times 1 -Exactly -ParameterFilter {
                $VmDefs[0].vmName -eq 'router-prod'
            }
        }

        It 'does not classify any VM when the preflight throws' {
            # Pins that classification is gated on preflight success: a
            # rejected batch must not Get-VM or Test-IpAddressInUse, both
            # of which could surface confusing errors on top of the real
            # preflight message.
            Initialize-Mocks
            Mock Assert-EnvironmentConsistency { throw "preflight nope" }
            { Select-VmsForProvisioning -VmDefs @((New-RouterVm)) } |
                Should -Throw -ExpectedMessage "*preflight nope*"
            Should -Invoke Get-VM              -Times 0
            Should -Invoke Test-IpAddressInUse -Times 0
        }
    }

    # ------------------------------------------------------------------
    Context 'new VM (Hyper-V absent, IP free)' {
    # ------------------------------------------------------------------

        It "annotates the VM with _state = 'new' and returns it" {
            Initialize-Mocks

            $result = @(Select-VmsForProvisioning -VmDefs @((New-RouterVm)))

            $result.Count        | Should -Be 1
            $result[0].vmName    | Should -Be 'router-prod'
            $result[0]._state    | Should -Be 'new'
        }
    }

    # ------------------------------------------------------------------
    Context 'existing VM (Hyper-V present, IP responds)' {
    # ------------------------------------------------------------------

        It "annotates the VM with _state = 'existing' and returns it" {
            # The existing VM owns its IP, so a ping response is expected
            # and confirms reachability for downstream reconcile.
            Initialize-Mocks
            Mock Get-VM              { [PSCustomObject]@{ Name = 'router-prod' } }
            Mock Test-IpAddressInUse { $true }

            $result = @(Select-VmsForProvisioning -VmDefs @((New-RouterVm)))

            $result.Count     | Should -Be 1
            $result[0].vmName | Should -Be 'router-prod'
            $result[0]._state | Should -Be 'existing'
        }
    }

    # ------------------------------------------------------------------
    Context 'IP conflict with unknown machine (Hyper-V absent, IP in use)' {
    # ------------------------------------------------------------------

        It 'drops the VM with a warning' {
            Initialize-Mocks
            Mock Test-IpAddressInUse { $true }

            $result = @(Select-VmsForProvisioning -VmDefs @((New-RouterVm)) `
                3> $null)

            $result.Count | Should -Be 0
        }
    }

    # ------------------------------------------------------------------
    Context 'existing VM that is offline (Hyper-V present, IP silent)' {
    # ------------------------------------------------------------------

        It 'drops the VM with a warning' {
            # An offline existing VM would fail post-provisioning at SSH
            # open with an opaque error - surface the state up front
            # instead so the operator can start the VM and re-run.
            Initialize-Mocks
            Mock Get-VM              { [PSCustomObject]@{ Name = 'router-prod' } }
            Mock Test-IpAddressInUse { $false }

            $result = @(Select-VmsForProvisioning -VmDefs @((New-RouterVm)) `
                3> $null)

            $result.Count | Should -Be 0
        }
    }

    # ------------------------------------------------------------------
    Context 'router ext0 addressing classification (DHCP vs static)' {
    # ------------------------------------------------------------------
        # An explicit-DHCP router (externalDhcp=$true) has no known static
        # IP at config-load time, so the static-IP probe Test-IpAddressInUse
        # does not apply. Classification falls back to VM-presence-only:
        # missing -> new, present -> existing. Conflict / offline warnings
        # cannot fire because there is no IP to conflict over. The absent-
        # field case is the contrast: it now defaults to static, so the
        # probe DOES run.

        It 'classifies a DHCP router with no Hyper-V VM as new (no IP probe)' {
            Initialize-Mocks
            # Ping must NOT run - the DHCP router has no known IP.
            $script:_pingCalled = $false
            Mock Test-IpAddressInUse {
                $script:_pingCalled = $true
                $false
            }

            $result = @(Select-VmsForProvisioning `
                -VmDefs @((New-RouterVm -ExternalDhcp $true)))

            $result.Count        | Should -Be 1
            $result[0]._state    | Should -Be 'new'
            $script:_pingCalled  | Should -Be $false
        }

        It 'classifies a DHCP router with an existing Hyper-V VM as existing (no IP probe)' {
            Initialize-Mocks
            Mock Get-VM { [PSCustomObject]@{ Name = 'router-prod' } }
            $script:_pingCalled = $false
            Mock Test-IpAddressInUse {
                $script:_pingCalled = $true
                $true
            }

            $result = @(Select-VmsForProvisioning `
                -VmDefs @((New-RouterVm -ExternalDhcp $true)))

            $result.Count        | Should -Be 1
            $result[0]._state    | Should -Be 'existing'
            $script:_pingCalled  | Should -Be $false
        }

        It 'treats a router with no externalDhcp field as static (schema default)' {
            # The schema default is now $false (static), so an operator who
            # omits the field gets the static path - Select-VmsForProvisioning
            # reads the absence the same way the seed generator does, and the
            # IP-conflict probe DOES run against the known ext0 IP.
            Initialize-Mocks
            $script:_pingCalled = $false
            Mock Test-IpAddressInUse {
                $script:_pingCalled = $true
                $false
            }

            # Pass $null to suppress the externalDhcp Add-Member in the
            # fixture, leaving the field genuinely absent.
            $result = @(Select-VmsForProvisioning `
                -VmDefs @((New-RouterVm -ExternalDhcp $null)))

            $result.Count        | Should -Be 1
            $result[0]._state    | Should -Be 'new'
            $script:_pingCalled  | Should -Be $true
        }
    }

    # ------------------------------------------------------------------
    Context 'workload behind a NAT router (feature 53 topology)' {
    # ------------------------------------------------------------------
        # Workloads sharing a router's privateSwitchName sit on the
        # per-environment private switch the host cannot route to.
        # Same posture as the DHCP-router branch: skip the IP probe,
        # classify on VM presence alone, let downstream wait-for-SSH
        # open a tunnel through the router to verify reach.
        #
        # Use a DHCP-mode router in these fixtures (-ExternalDhcp $true)
        # so the router itself ALSO skips the probe; the per-IP probe
        # filter below then catches a regression that re-introduces the
        # probe specifically for the workload row.

        It 'classifies a workload-behind-router as new when no Hyper-V VM exists (no IP probe)' {
            Initialize-Mocks
            $script:_workloadProbeCalled = $false
            Mock Test-IpAddressInUse -ParameterFilter { $IpAddress -eq '10.0.0.10' } {
                $script:_workloadProbeCalled = $true
                $false
            }

            $result = @(Select-VmsForProvisioning -VmDefs @(
                (New-RouterVm -ExternalDhcp $true),
                (New-TestVm -VmName 'wl' -IpAddress '10.0.0.10')
            ))

            ($result | Where-Object vmName -eq 'wl')._state | Should -Be 'new'
            $script:_workloadProbeCalled | Should -Be $false
        }

        It 'classifies a workload-behind-router as existing when its Hyper-V VM exists (no IP probe)' {
            Initialize-Mocks
            Mock Get-VM -ParameterFilter { $Name -eq 'wl' } {
                [PSCustomObject]@{ Name = 'wl' }
            }
            $script:_workloadProbeCalled = $false
            Mock Test-IpAddressInUse -ParameterFilter { $IpAddress -eq '10.0.0.10' } {
                $script:_workloadProbeCalled = $true
                $true
            }

            $result = @(Select-VmsForProvisioning -VmDefs @(
                (New-RouterVm -ExternalDhcp $true),
                (New-TestVm -VmName 'wl' -IpAddress '10.0.0.10')
            ))

            ($result | Where-Object vmName -eq 'wl')._state | Should -Be 'existing'
            $script:_workloadProbeCalled | Should -Be $false
        }
    }

    # ------------------------------------------------------------------
    Context 'mixed batch' {
    # ------------------------------------------------------------------

        It 'classifies each workload-behind-router on VM presence alone' {
            # When a router is in the batch, every workload sharing
            # its privateSwitchName lives on the per-environment
            # private switch the host has no route to. The static-IP
            # probe cannot succeed for them, so the four-case decision
            # matrix collapses to a two-case classification on VM
            # presence (mirrors the DHCP-router branch). The conflict
            # / offline warnings that fire for directly-routable
            # workloads do not apply here - their IPs were never
            # reachable from the host to begin with.
            Initialize-Mocks
            Mock Get-VM -ParameterFilter { $Name -eq 'router-prod' } { $null }
            Mock Get-VM -ParameterFilter { $Name -eq 'new-vm' }      { $null }
            Mock Get-VM -ParameterFilter { $Name -eq 'existing-vm' } {
                [PSCustomObject]@{ Name = 'existing-vm' }
            }

            # Per-workload-IP probe filters so a regression that re-
            # introduces the broken probe gets caught here. The router
            # is DHCP-mode (no static probe of its own); workloads
            # behind it must also skip the probe.
            $script:_newProbeCalled      = $false
            $script:_existingProbeCalled = $false
            Mock Test-IpAddressInUse -ParameterFilter { $IpAddress -eq '10.0.0.1' } {
                $script:_newProbeCalled = $true
                $false
            }
            Mock Test-IpAddressInUse -ParameterFilter { $IpAddress -eq '10.0.0.2' } {
                $script:_existingProbeCalled = $true
                $true
            }

            $vms = @(
                (New-RouterVm -ExternalDhcp $true),
                (New-TestVm -VmName 'new-vm'      -IpAddress '10.0.0.1'),
                (New-TestVm -VmName 'existing-vm' -IpAddress '10.0.0.2')
            )

            $result = @(Select-VmsForProvisioning -VmDefs $vms 3> $null)

            $result.Count                                            | Should -Be 3
            ($result | Where-Object vmName -eq 'router-prod')._state | Should -Be 'new'
            ($result | Where-Object vmName -eq 'new-vm')._state      | Should -Be 'new'
            ($result | Where-Object vmName -eq 'existing-vm')._state | Should -Be 'existing'
            $script:_newProbeCalled                                  | Should -Be $false
            $script:_existingProbeCalled                             | Should -Be $false
        }
    }
}
