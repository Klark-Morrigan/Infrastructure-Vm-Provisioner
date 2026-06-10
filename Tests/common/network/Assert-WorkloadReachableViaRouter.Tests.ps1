BeforeAll {
    # Infrastructure.HyperV's Invoke-SshClientCommand needs Posh-SSH's
    # Renci.SshNet types in process. Stub it so Pester's Mock layer can
    # replace it in each test - the helper under test does not care
    # what the SshClient parameter object actually is, it just forwards.
    function Invoke-SshClientCommand {
        param($SshClient, $Command)
        [PSCustomObject]@{ ExitStatus = 0; Output = @(); Error = '' }
    }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\common\network\Assert-WorkloadReachableViaRouter.ps1"

    function New-SuccessfulProbe {
        # Convenience builder for the SSH-banner-success result shape.
        [PSCustomObject]@{
            ExitStatus = 0
            Output     = @('SSH-2.0-OpenSSH_9.6p1')
            Error      = ''
        }
    }
    function New-FailedProbe {
        [PSCustomObject]@{ ExitStatus = 1; Output = @(); Error = '' }
    }
}

Describe 'Assert-WorkloadReachableViaRouter' {

    BeforeEach {
        # JumpClient is opaque to the helper - a sentinel object is
        # enough for Should -Invoke -ParameterFilter to identify it.
        $script:jumpClient = [PSCustomObject]@{ _stub = 'jump-client' }
        $script:diagFolder = Join-Path ([System.IO.Path]::GetTempPath()) `
                                       ("awrvr-" + [Guid]::NewGuid().Guid)
    }

    AfterEach {
        if (Test-Path -Path $script:diagFolder -PathType Container) {
            Remove-Item -Path $script:diagFolder -Recurse -Force `
                        -ErrorAction SilentlyContinue
        }
    }

    Context 'happy path' {

        It 'returns silently when the workload banner arrives on the first probe' {
            Mock Invoke-SshClientCommand { New-SuccessfulProbe }

            { Assert-WorkloadReachableViaRouter `
                -JumpClient     $script:jumpClient `
                -WorkloadIp     '10.99.0.10' `
                -WorkloadVmName 'wl' `
                -RouterVmName   'router-prod' `
                -DiagFolder     $script:diagFolder } |
                Should -Not -Throw
        }

        It 'issues the nc banner-read probe targeting the workload IP via the jump client' {
            $script:_cmd    = $null
            $script:_client = $null
            Mock Invoke-SshClientCommand {
                $script:_cmd    = $Command
                $script:_client = $SshClient
                New-SuccessfulProbe
            }

            Assert-WorkloadReachableViaRouter `
                -JumpClient     $script:jumpClient `
                -WorkloadIp     '10.99.0.10' `
                -WorkloadVmName 'wl' `
                -RouterVmName   'router-prod' `
                -DiagFolder     $script:diagFolder

            $script:_cmd        | Should -Match 'nc -w 3 10\.99\.0\.10 22'
            $script:_cmd        | Should -Match 'head -c 4'
            $script:_client._stub | Should -Be 'jump-client'
        }

        It 'invokes OnPoll once per iteration before the probe' {
            $script:_pollFires = 0
            $script:_probeCalls = 0
            # First two probes fail (no banner), third succeeds.
            Mock Invoke-SshClientCommand {
                $script:_probeCalls++
                if ($script:_probeCalls -ge 3) { New-SuccessfulProbe }
                else                            { New-FailedProbe }
            }
            Mock Start-Sleep { }

            Assert-WorkloadReachableViaRouter `
                -JumpClient          $script:jumpClient `
                -WorkloadIp          '10.99.0.10' `
                -WorkloadVmName      'wl' `
                -RouterVmName        'router-prod' `
                -DiagFolder          $script:diagFolder `
                -PollIntervalSeconds 0 `
                -OnPoll              { $script:_pollFires++ }

            $script:_pollFires  | Should -Be 3
            $script:_probeCalls | Should -Be 3
        }
    }

    Context 'OnPoll throws' {

        It 'propagates an OnPoll throw without running the probe' {
            $script:_probeCalls = 0
            Mock Invoke-SshClientCommand {
                $script:_probeCalls++
                New-FailedProbe
            }

            { Assert-WorkloadReachableViaRouter `
                -JumpClient     $script:jumpClient `
                -WorkloadIp     '10.99.0.10' `
                -WorkloadVmName 'wl' `
                -RouterVmName   'router-prod' `
                -DiagFolder     $script:diagFolder `
                -OnPoll         { throw 'VM stopped unexpectedly during probe.' } } |
                Should -Throw -ExpectedMessage '*VM stopped unexpectedly*'

            $script:_probeCalls | Should -Be 0
        }
    }

    Context 'gate failure - diagnostic capture' {

        BeforeEach {
            # Drive the helper into the failure branch: probe always
            # returns a non-banner result. The diag command (the one
            # with 'nft list ruleset' in it) returns a synthetic bundle
            # so the helper has something to write + extract a hint from.
            $script:_diagBody = "=== diag bundle ===`nConnection timed out`n"
            Mock Invoke-SshClientCommand {
                if ($Command -match 'nft list ruleset') {
                    [PSCustomObject]@{
                        ExitStatus = 0
                        Output     = $script:_diagBody -split "`n"
                        Error      = ''
                    }
                } else {
                    New-FailedProbe
                }
            }
            Mock Start-Sleep { }
        }

        It 'throws a directed error naming the router, workload, and IP' {
            { Assert-WorkloadReachableViaRouter `
                -JumpClient      $script:jumpClient `
                -WorkloadIp      '10.99.0.10' `
                -WorkloadVmName  'wl' `
                -RouterVmName    'router-prod' `
                -DiagFolder      $script:diagFolder `
                -TimeoutSeconds  0 } |
                Should -Throw -ExpectedMessage "*Router 'router-prod' cannot reach workload 'wl' at 10.99.0.10:22*"
        }

        It 'writes router-side-probe.log under the supplied DiagFolder' {
            try {
                Assert-WorkloadReachableViaRouter `
                    -JumpClient     $script:jumpClient `
                    -WorkloadIp     '10.99.0.10' `
                    -WorkloadVmName 'wl' `
                    -RouterVmName   'router-prod' `
                    -DiagFolder     $script:diagFolder `
                    -TimeoutSeconds 0
            } catch { }

            $logPath = Join-Path $script:diagFolder 'router-side-probe.log'
            Test-Path -Path $logPath -PathType Leaf | Should -BeTrue
            (Get-Content -Path $logPath -Raw) | Should -Match 'diag bundle'
        }

        It 'creates the DiagFolder when it does not already exist' {
            # Sanity: BeforeEach picks a fresh GUID path, so the folder
            # does not exist before the call.
            Test-Path -Path $script:diagFolder | Should -BeFalse

            try {
                Assert-WorkloadReachableViaRouter `
                    -JumpClient     $script:jumpClient `
                    -WorkloadIp     '10.99.0.10' `
                    -WorkloadVmName 'wl' `
                    -RouterVmName   'router-prod' `
                    -DiagFolder     $script:diagFolder `
                    -TimeoutSeconds 0
            } catch { }

            Test-Path -Path $script:diagFolder -PathType Container | Should -BeTrue
        }

        It 'embeds the diag file path in the thrown error message' {
            try {
                Assert-WorkloadReachableViaRouter `
                    -JumpClient     $script:jumpClient `
                    -WorkloadIp     '10.99.0.10' `
                    -WorkloadVmName 'wl' `
                    -RouterVmName   'router-prod' `
                    -DiagFolder     $script:diagFolder `
                    -TimeoutSeconds 0
            } catch {
                $_.Exception.Message | Should -Match 'router-side-probe\.log'
            }
        }
    }

    Context 'gate failure - symptom hints' {

        BeforeEach {
            $script:_diagBody = ''
            Mock Invoke-SshClientCommand {
                if ($Command -match 'nft list ruleset') {
                    [PSCustomObject]@{
                        ExitStatus = 0
                        Output     = $script:_diagBody -split "`n"
                        Error      = ''
                    }
                } else {
                    New-FailedProbe
                }
            }
            Mock Start-Sleep { }
        }

        It 'hints "100% packet loss" => layer-2 / priv0 problem' {
            $script:_diagBody = "ping output`n100% packet loss`n"
            try {
                Assert-WorkloadReachableViaRouter `
                    -JumpClient $script:jumpClient -WorkloadIp '10.99.0.10' `
                    -WorkloadVmName 'wl' -RouterVmName 'r' `
                    -DiagFolder $script:diagFolder -TimeoutSeconds 0
            } catch {
                $_.Exception.Message | Should -Match 'layer-2 / priv0 problem'
            }
        }

        It 'hints "No route to host" => router missing priv0 route' {
            $script:_diagBody = "ping: No route to host`n"
            try {
                Assert-WorkloadReachableViaRouter `
                    -JumpClient $script:jumpClient -WorkloadIp '10.99.0.10' `
                    -WorkloadVmName 'wl' -RouterVmName 'r' `
                    -DiagFolder $script:diagFolder -TimeoutSeconds 0
            } catch {
                $_.Exception.Message | Should -Match 'no priv0 / 10\.99\.0\.0 route'
            }
        }

        It 'hints "Connection refused" => sshd not bound to priv0-side IP' {
            $script:_diagBody = "nc: Connection refused`n"
            try {
                Assert-WorkloadReachableViaRouter `
                    -JumpClient $script:jumpClient -WorkloadIp '10.99.0.10' `
                    -WorkloadVmName 'wl' -RouterVmName 'r' `
                    -DiagFolder $script:diagFolder -TimeoutSeconds 0
            } catch {
                $_.Exception.Message | Should -Match 'sshd not bound to the priv0-side IP'
            }
        }

        It 'hints "Connection timed out" => workload ufw blocking' {
            $script:_diagBody = "nc: Connection timed out`n"
            try {
                Assert-WorkloadReachableViaRouter `
                    -JumpClient $script:jumpClient -WorkloadIp '10.99.0.10' `
                    -WorkloadVmName 'wl' -RouterVmName 'r' `
                    -DiagFolder $script:diagFolder -TimeoutSeconds 0
            } catch {
                $_.Exception.Message | Should -Match 'workload firewall \(ufw\) likely blocking inbound'
            }
        }

        It 'hints "ip_forward = 0" => router sysctl never applied' {
            $script:_diagBody = "net.ipv4.ip_forward = 0`n"
            try {
                Assert-WorkloadReachableViaRouter `
                    -JumpClient $script:jumpClient -WorkloadIp '10.99.0.10' `
                    -WorkloadVmName 'wl' -RouterVmName 'r' `
                    -DiagFolder $script:diagFolder -TimeoutSeconds 0
            } catch {
                $_.Exception.Message | Should -Match 'ip_forward is 0 - router sysctl never applied'
            }
        }

        It 'omits the hint clause when no recognised signal is present' {
            $script:_diagBody = "nothing actionable here`n"
            try {
                Assert-WorkloadReachableViaRouter `
                    -JumpClient $script:jumpClient -WorkloadIp '10.99.0.10' `
                    -WorkloadVmName 'wl' -RouterVmName 'r' `
                    -DiagFolder $script:diagFolder -TimeoutSeconds 0
            } catch {
                # No 'Symptom:' substring in the message when nothing matched.
                $_.Exception.Message | Should -Not -Match 'Symptom:'
            }
        }
    }

    Context 'diag capture itself fails' {

        It 'still throws the reachability error, with a warning about diag capture' {
            # Probe always fails. The diagnostic call (second Invoke-
            # SshClientCommand) itself throws - simulates a router
            # whose SSH session has dropped by the time we ask for
            # diags. The helper must still throw the reachability
            # error, just without a diag-pointer or hint, and emit a
            # warning.
            Mock Invoke-SshClientCommand {
                if ($Command -match 'nft list ruleset') {
                    throw 'router SSH session dropped'
                } else {
                    New-FailedProbe
                }
            }
            Mock Start-Sleep { }

            $script:_warnings = @()
            Mock Write-Warning { $script:_warnings += $Message }

            try {
                Assert-WorkloadReachableViaRouter `
                    -JumpClient $script:jumpClient -WorkloadIp '10.99.0.10' `
                    -WorkloadVmName 'wl' -RouterVmName 'r' `
                    -DiagFolder $script:diagFolder -TimeoutSeconds 0
            } catch {
                $_.Exception.Message | Should -Match "Router 'r' cannot reach workload"
                $_.Exception.Message | Should -Not -Match 'Diagnostics:'
            }
            ($script:_warnings -join "`n") | Should -Match 'Router-side diagnostic capture itself failed'
        }
    }
}
