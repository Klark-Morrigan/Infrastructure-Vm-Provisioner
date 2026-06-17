BeforeAll {
    function Get-VmKvpIpAddress {
        param($VmName, $SwitchName, $TimeoutMinutes, $PollIntervalSeconds, $OnPoll)
        '0.0.0.0'
    }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\common\network\Resolve-ExistingRouterIp.ps1"

    function New-ExistingRouterVm {
        param(
            [string] $VmName             = 'router-prod',
            [string] $ExternalSwitchName = 'ExternalSwitch-Shared'
        )
        $vm = [PSCustomObject]@{
            vmName             = $VmName
            externalSwitchName = $ExternalSwitchName
        }
        $vm | Add-Member -MemberType NoteProperty -Name '_state' `
                         -Value 'existing'
        $vm
    }
}

Describe 'Resolve-ExistingRouterIp' {

    Context 'existing router without an ipAddress' {

        It 'calls Get-VmKvpIpAddress with the router vmName + externalSwitchName' {
            Mock Get-VmKvpIpAddress { '192.168.1.211' }

            $router = New-ExistingRouterVm
            Resolve-ExistingRouterIp -RouterVm $router

            Should -Invoke Get-VmKvpIpAddress -Times 1 -Exactly -ParameterFilter {
                $VmName     -eq 'router-prod' -and
                $SwitchName -eq 'ExternalSwitch-Shared'
            }
        }

        It 'stamps the discovered IP back onto the same RouterVm object' {
            # Object-identity test: the workload's _RouterVm reference
            # in provision.ps1 step 7 IS this same object. Writing to
            # a copy here would silently leave $_RouterVm.ipAddress
            # absent and the workload's tunnel-open would throw.
            Mock Get-VmKvpIpAddress { '192.168.1.211' }

            $router = New-ExistingRouterVm
            Resolve-ExistingRouterIp -RouterVm $router

            $router.PSObject.Properties['ipAddress'] | Should -Not -BeNullOrEmpty
            $router.ipAddress | Should -Be '192.168.1.211'
        }

        It 'propagates a Get-VmKvpIpAddress throw without stamping anything' {
            # The helper surfaces a directed "VM is not Running" error
            # when the existing router is Off; the throw must reach
            # the caller intact (provision.ps1's step 7 needs to know
            # to abort the env).
            Mock Get-VmKvpIpAddress { throw "Hyper-V VM 'router-prod' is not Running (state: Off)." }

            $router = New-ExistingRouterVm
            { Resolve-ExistingRouterIp -RouterVm $router } |
                Should -Throw -ExpectedMessage '*is not Running*'
            $router.PSObject.Properties['ipAddress'] | Should -BeNullOrEmpty
        }
    }

    Context 'no-op skip conditions' {

        It 'does not call KVP when the router is _state == new' {
            # create-vm.ps1 owns the KVP discovery for new routers as
            # part of its own wait-for-SSH boot sequence. Calling it
            # here too would race-discover the IP before the VM had
            # finished booting.
            $script:_kvpCalls = 0
            Mock Get-VmKvpIpAddress { $script:_kvpCalls++; '0.0.0.0' }

            $router = New-ExistingRouterVm
            $router._state = 'new'
            Resolve-ExistingRouterIp -RouterVm $router

            $script:_kvpCalls | Should -Be 0
            $router.PSObject.Properties['ipAddress'] | Should -BeNullOrEmpty
        }

        It 'does not call KVP when the router already has an ipAddress' {
            # Static-mode operators (externalDhcp=false) supply a known
            # ipAddress in VmProvisionerConfig. The helper must NOT
            # overwrite it - a re-discovery would burn a KVP round-trip
            # and could surface the same IP under a different switch
            # name's MAC mapping in flaky multi-NIC scenarios.
            $script:_kvpCalls = 0
            Mock Get-VmKvpIpAddress { $script:_kvpCalls++; '0.0.0.0' }

            $router = New-ExistingRouterVm
            $router | Add-Member -MemberType NoteProperty -Name 'ipAddress' `
                                  -Value '192.168.1.2'
            Resolve-ExistingRouterIp -RouterVm $router

            $script:_kvpCalls | Should -Be 0
            $router.ipAddress | Should -Be '192.168.1.2'
        }

        It 'does not call KVP when the router has no _state property at all' {
            # Defensive: a fixture without _state predates Select-VmsForProvisioning's
            # tagging and cannot be classified. The helper treats this
            # as "not existing" and skips - the alternative (running
            # KVP on a never-classified VM) is the wrong default for
            # an unknown lifecycle state.
            $script:_kvpCalls = 0
            Mock Get-VmKvpIpAddress { $script:_kvpCalls++; '0.0.0.0' }

            $router = [PSCustomObject]@{
                vmName             = 'router-prod'
                externalSwitchName = 'ExternalSwitch-Shared'
            }
            Resolve-ExistingRouterIp -RouterVm $router

            $script:_kvpCalls | Should -Be 0
        }
    }
}
