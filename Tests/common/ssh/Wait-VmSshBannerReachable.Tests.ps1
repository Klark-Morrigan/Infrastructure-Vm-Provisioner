BeforeAll {
    # Stub Infrastructure.HyperV's probes so Pester can Mock them.
    function Test-VmSshPort {
        param([string] $IpAddress, [int] $Port = 22)
        $false
    }
    function Test-SshBanner {
        param([string] $IpAddress, [int] $Port = 22,
              [int] $TimeoutMilliseconds = 3000)
        $true
    }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\common\ssh\Wait-VmSshBannerReachable.ps1"
}

Describe 'Wait-VmSshBannerReachable' {

    BeforeEach {
        # Far-future deadline keeps the loop alive for happy-path
        # tests; failure-path tests pass a past deadline directly.
        $script:future = (Get-Date).AddMinutes(10)
    }

    Context 'happy path' {

        It 'returns $true when TCP accepts AND the banner read returns SSH-' {
            Mock Test-VmSshPort { $true }
            Mock Test-SshBanner { $true }

            $result = Wait-VmSshBannerReachable `
                          -IpAddress '127.0.0.1' -Port 22 `
                          -Deadline  $script:future `
                          -PollIntervalSeconds 0
            $result | Should -BeTrue
        }

        It 'invokes Test-VmSshPort and Test-SshBanner with the supplied endpoint' {
            Mock Test-VmSshPort { $true }
            Mock Test-SshBanner { $true }

            Wait-VmSshBannerReachable `
                -IpAddress '10.99.0.10' -Port 22 `
                -Deadline  $script:future `
                -PollIntervalSeconds 0 | Out-Null

            Should -Invoke Test-VmSshPort -Times 1 -Exactly -ParameterFilter {
                $IpAddress -eq '10.99.0.10' -and $Port -eq 22
            }
            Should -Invoke Test-SshBanner -Times 1 -Exactly -ParameterFilter {
                $IpAddress -eq '10.99.0.10' -and $Port -eq 22
            }
        }
    }

    Context 'banner gate' {

        It 'keeps polling when TCP accepts but the banner does not arrive' {
            # Models the SSH.NET-tunnel false positive: TCP accepts
            # instantly via the local ForwardedPortLocal listener;
            # the banner read fails until the workload's sshd is
            # actually serving. The loop must NOT exit on TCP-only
            # success - that was the original bug Test-SshBanner
            # was added to gate against.
            Mock Test-VmSshPort { $true }
            $script:_bannerCalls = 0
            Mock Test-SshBanner {
                $script:_bannerCalls++
                $script:_bannerCalls -ge 3
            }
            Mock Start-Sleep { }

            $result = Wait-VmSshBannerReachable `
                          -IpAddress '127.0.0.1' -Port 22 `
                          -Deadline  $script:future `
                          -PollIntervalSeconds 0
            $result               | Should -BeTrue
            $script:_bannerCalls  | Should -Be 3
        }

        It 'does NOT call Test-SshBanner when Test-VmSshPort returns $false' {
            # Saves the per-banner-probe network cost when TCP
            # itself is closed. Verified by Should -Invoke -Times 0
            # since the banner check is gated behind the TCP probe.
            Mock Test-VmSshPort { $false }
            Mock Test-SshBanner { $true }
            Mock Start-Sleep { }

            Wait-VmSshBannerReachable `
                -IpAddress '127.0.0.1' -Port 22 `
                -Deadline  (Get-Date).AddMilliseconds(50) `
                -PollIntervalSeconds 0 | Out-Null

            Should -Invoke Test-SshBanner -Times 0 -Exactly
        }
    }

    Context 'deadline' {

        It 'returns $false when the deadline expires before the banner arrives' {
            Mock Test-VmSshPort { $true }
            Mock Test-SshBanner { $false }
            Mock Start-Sleep { }

            $result = Wait-VmSshBannerReachable `
                          -IpAddress '127.0.0.1' -Port 22 `
                          -Deadline  (Get-Date).AddMilliseconds(-1) `
                          -PollIntervalSeconds 0
            $result | Should -BeFalse
        }

        It 'returns $false immediately when the deadline is already in the past' {
            $script:_probeCalls = 0
            Mock Test-VmSshPort {
                $script:_probeCalls++
                $true
            }
            Mock Test-SshBanner { $true }

            $result = Wait-VmSshBannerReachable `
                          -IpAddress '127.0.0.1' -Port 22 `
                          -Deadline  (Get-Date).AddMinutes(-10) `
                          -PollIntervalSeconds 0
            $result              | Should -BeFalse
            $script:_probeCalls  | Should -Be 0
        }
    }

    Context '-OnPoll callback' {

        It 'invokes OnPoll once per "not ready yet" iteration BEFORE the probe' {
            $script:_pollFires  = 0
            $script:_probeCalls = 0
            $script:_pollOrder  = @()
            Mock Test-VmSshPort {
                $script:_probeCalls++
                $script:_pollOrder += "probe-$($script:_probeCalls)"
                $script:_probeCalls -ge 3
            }
            Mock Test-SshBanner { $true }
            Mock Start-Sleep { }

            Wait-VmSshBannerReachable `
                -IpAddress '127.0.0.1' -Port 22 `
                -Deadline  $script:future `
                -PollIntervalSeconds 0 `
                -OnPoll {
                    $script:_pollFires++
                    $script:_pollOrder += "onpoll-$($script:_pollFires)"
                } | Out-Null

            $script:_pollFires | Should -Be 3
            $script:_pollOrder | Should -Be @(
                'onpoll-1','probe-1','onpoll-2','probe-2','onpoll-3','probe-3')
        }

        It 'propagates an OnPoll throw without calling the probe' {
            $script:_probeCalls = 0
            Mock Test-VmSshPort {
                $script:_probeCalls++
                $false
            }

            { Wait-VmSshBannerReachable `
                -IpAddress '127.0.0.1' -Port 22 `
                -Deadline  $script:future `
                -PollIntervalSeconds 0 `
                -OnPoll { throw 'VM no longer running' } } |
                Should -Throw -ExpectedMessage '*VM no longer running*'

            $script:_probeCalls | Should -Be 0
        }
    }
}
