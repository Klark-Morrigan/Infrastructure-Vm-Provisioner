<#
.SYNOPSIS
    Unit tests for Wait-VmSshAccessible.

.DESCRIPTION
    Pins the topology-aware reachability contract:
      - workload (RouterVm present) opens one tunnel through the router and
        probes the tunnel's loopback endpoint;
      - router / standalone (RouterVm $null) probes the VM IP on :22 with no
        tunnel;
      - the tunnel is always disposed (success, timeout, or gate throw) and
        never disposed on the router branch (none opened);
      - the -OnTunnelOpened seam fires once with the live tunnel, after the
        forward opens and before the banner poll, and only for workloads;
      - the -OnPoll scriptblock is forwarded unchanged to the banner gate;
      - a timeout is a $false result, not an exception;
      - ElapsedSeconds is populated on both outcomes.

    New-VmSshTunnel and Wait-VmSshBannerReachable are the only dependencies
    and are stubbed/mocked here; their own behaviour is covered by their own
    suites.
#>

BeforeAll {
    # Stub the dependencies so Pester's Mock can attach by name. Params are
    # declared so ParameterFilter can bind the named args.
    function New-VmSshTunnel {
        # The real cmdlet takes a plaintext jump username/password pair
        # SSH.NET demands; the stub mirrors that shape so ParameterFilter
        # can bind the creds. Suppress the credential rules on the double,
        # exactly as the production cmdlet suppresses them (ID '' for the
        # function-scoped UsernameAndPassword rule).
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSAvoidUsingPlainTextForPassword', 'JumpPassword')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSAvoidUsingUsernameAndPasswordParams', '')]
        param(
            [string] $TargetIp,
            [string] $JumpHostIp,
            [string] $JumpUsername,
            [string] $JumpPassword,
            [uint32] $TargetPort = 22
        )
    }
    function Wait-VmSshBannerReachable {
        param(
            [string]      $IpAddress,
            [int]         $Port,
            [datetime]    $Deadline,
            [int]         $PollIntervalSeconds = 10,
            [scriptblock] $OnPoll
        )
        $true
    }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\common\ssh\Wait-VmSshAccessible.ps1"

    # Recording tunnel double. Dispose increments a script-scoped counter so
    # tests can assert teardown; JumpClient is a sentinel the OnTunnelOpened
    # seam is expected to receive.
    function New-FakeTunnel {
        [PSCustomObject]@{
            LocalHost  = '127.0.0.1'
            LocalPort  = 50022
            JumpClient = 'sentinel-jump-client'
        } | Add-Member -PassThru -MemberType ScriptMethod -Name Dispose -Value {
            $script:disposeCalls++
        }
    }

    function New-RouterDef {
        [PSCustomObject]@{
            vmName    = 'router-1'
            ipAddress = '10.99.0.1'
            username  = 'ruser'
            password  = 'rpass'
        }
    }
    function New-WorkloadDef {
        [PSCustomObject]@{ vmName = 'workload-1'; ipAddress = '10.99.0.10' }
    }
}

Describe 'Wait-VmSshAccessible' {

    BeforeEach {
        # Far-future deadline keeps the (mocked) gate from caring about time;
        # disposeCalls resets per test for clean teardown assertions.
        $script:future       = (Get-Date).AddMinutes(10)
        $script:disposeCalls = 0
        Mock New-VmSshTunnel { New-FakeTunnel }
        Mock Wait-VmSshBannerReachable { $true }
    }

    Context 'workload branch (RouterVm present)' {

        It 'opens the tunnel once with the router IP and credentials' {
            Wait-VmSshAccessible -Vm (New-WorkloadDef) -RouterVm (New-RouterDef) `
                -Deadline $script:future -PollIntervalSeconds 0 | Out-Null

            Should -Invoke New-VmSshTunnel -Times 1 -Exactly -ParameterFilter {
                $TargetIp     -eq '10.99.0.10' -and
                $JumpHostIp   -eq '10.99.0.1'  -and
                $JumpUsername -eq 'ruser'      -and
                $JumpPassword -eq 'rpass'
            }
        }

        It 'probes the tunnel loopback endpoint, not the workload IP' {
            Wait-VmSshAccessible -Vm (New-WorkloadDef) -RouterVm (New-RouterDef) `
                -Deadline $script:future -PollIntervalSeconds 0 | Out-Null

            Should -Invoke Wait-VmSshBannerReachable -Times 1 -Exactly `
                -ParameterFilter { $IpAddress -eq '127.0.0.1' -and $Port -eq 50022 }
        }

        It 'returns Reachable $true with the probed endpoint' {
            $result = Wait-VmSshAccessible `
                          -Vm (New-WorkloadDef) -RouterVm (New-RouterDef) `
                          -Deadline $script:future -PollIntervalSeconds 0
            $result.Reachable | Should -BeTrue
            $result.ProbeIp   | Should -Be '127.0.0.1'
            $result.ProbePort | Should -Be 50022
        }

        It 'disposes the tunnel exactly once' {
            Wait-VmSshAccessible -Vm (New-WorkloadDef) -RouterVm (New-RouterDef) `
                -Deadline $script:future -PollIntervalSeconds 0 | Out-Null
            $script:disposeCalls | Should -Be 1
        }
    }

    Context 'router / standalone branch (RouterVm $null)' {

        It 'does not open a tunnel' {
            Wait-VmSshAccessible -Vm (New-RouterDef) -RouterVm $null `
                -Deadline $script:future -PollIntervalSeconds 0 | Out-Null
            Should -Invoke New-VmSshTunnel -Times 0 -Exactly
        }

        It 'probes the VM IP on port 22 directly' {
            Wait-VmSshAccessible -Vm (New-RouterDef) -RouterVm $null `
                -Deadline $script:future -PollIntervalSeconds 0 | Out-Null
            Should -Invoke Wait-VmSshBannerReachable -Times 1 -Exactly `
                -ParameterFilter { $IpAddress -eq '10.99.0.1' -and $Port -eq 22 }
        }

        It 'never disposes a tunnel because none was opened' {
            Wait-VmSshAccessible -Vm (New-RouterDef) -RouterVm $null `
                -Deadline $script:future -PollIntervalSeconds 0 | Out-Null
            $script:disposeCalls | Should -Be 0
        }
    }

    Context '-OnTunnelOpened seam' {

        It 'invokes the hook once with the tunnel, before the banner poll' {
            $script:order      = @()
            $script:seenClient = $null
            Mock Wait-VmSshBannerReachable {
                $script:order += 'banner'
                $true
            }
            $onOpened = {
                param($tunnel)
                $script:order      += 'tunnel-opened'
                $script:seenClient  = $tunnel.JumpClient
            }

            Wait-VmSshAccessible -Vm (New-WorkloadDef) -RouterVm (New-RouterDef) `
                -Deadline $script:future -PollIntervalSeconds 0 `
                -OnTunnelOpened $onOpened | Out-Null

            $script:order      | Should -Be @('tunnel-opened', 'banner')
            $script:seenClient | Should -Be 'sentinel-jump-client'
        }

        It 'does not invoke the hook on the router branch' {
            $script:hookFired = $false
            Wait-VmSshAccessible -Vm (New-RouterDef) -RouterVm $null `
                -Deadline $script:future -PollIntervalSeconds 0 `
                -OnTunnelOpened { $script:hookFired = $true } | Out-Null
            $script:hookFired | Should -BeFalse
        }

        It 'still runs the banner poll when the hook is omitted' {
            Wait-VmSshAccessible -Vm (New-WorkloadDef) -RouterVm (New-RouterDef) `
                -Deadline $script:future -PollIntervalSeconds 0 | Out-Null
            Should -Invoke Wait-VmSshBannerReachable -Times 1 -Exactly
        }

        It 'disposes the tunnel and propagates when the hook throws' {
            { Wait-VmSshAccessible -Vm (New-WorkloadDef) -RouterVm (New-RouterDef) `
                -Deadline $script:future -PollIntervalSeconds 0 `
                -OnTunnelOpened { throw 'gate failed' } } |
                Should -Throw -ExpectedMessage '*gate failed*'

            $script:disposeCalls | Should -Be 1
            Should -Invoke Wait-VmSshBannerReachable -Times 0 -Exactly
        }
    }

    Context '-OnPoll forwarding' {

        It 'forwards the exact OnPoll scriptblock instance to the banner gate' {
            $script:forwarded = $null
            Mock Wait-VmSshBannerReachable {
                $script:forwarded = $OnPoll
                $true
            }
            $onPoll = { 'vm-state guard' }

            Wait-VmSshAccessible -Vm (New-RouterDef) -RouterVm $null `
                -Deadline $script:future -PollIntervalSeconds 0 `
                -OnPoll $onPoll | Out-Null

            [object]::ReferenceEquals($script:forwarded, $onPoll) | Should -BeTrue
        }
    }

    Context 'timeout (banner poll returns $false)' {

        It 'returns Reachable $false and disposes the tunnel without throwing' {
            # A bare call (not wrapped in Should -Not -Throw) is the no-throw
            # assertion: an unhandled throw on timeout would fail the test
            # here. A timeout is a result, not an error - the caller decides.
            Mock Wait-VmSshBannerReachable { $false }
            $result = Wait-VmSshAccessible `
                          -Vm (New-WorkloadDef) -RouterVm (New-RouterDef) `
                          -Deadline $script:future -PollIntervalSeconds 0
            $result.Reachable    | Should -BeFalse
            $script:disposeCalls | Should -Be 1
        }
    }

    Context 'ElapsedSeconds' {

        It 'is populated on a reachable result' {
            Mock Wait-VmSshBannerReachable { $true }
            $result = Wait-VmSshAccessible -Vm (New-RouterDef) -RouterVm $null `
                          -Deadline $script:future -PollIntervalSeconds 0
            $result.ElapsedSeconds | Should -BeOfType [int]
            $result.ElapsedSeconds | Should -BeGreaterOrEqual 0
        }

        It 'is populated on a timeout result' {
            Mock Wait-VmSshBannerReachable { $false }
            $result = Wait-VmSshAccessible -Vm (New-RouterDef) -RouterVm $null `
                          -Deadline $script:future -PollIntervalSeconds 0
            $result.Reachable      | Should -BeFalse
            $result.ElapsedSeconds | Should -BeOfType [int]
            $result.ElapsedSeconds | Should -BeGreaterOrEqual 0
        }
    }
}
