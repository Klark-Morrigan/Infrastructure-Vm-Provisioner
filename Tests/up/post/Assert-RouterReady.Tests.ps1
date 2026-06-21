BeforeAll {
    # Pester needs the dependent command to exist before mocking; stub
    # at file scope so per-test Mocks attach.
    function Invoke-SshClientCommand { param($SshClient, $Command) }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\post\Assert-RouterReady.ps1"

    # Default SSH responses for a fully-ready router. Tests that exercise a
    # failure re-Mock Invoke-SshClientCommand to flip one command's output.
    function Set-HappyRouterMock {
        Mock Invoke-SshClientCommand {
            param($SshClient, $Command)
            switch -Regex ($Command) {
                'sysctl -n net\.ipv4\.ip_forward' {
                    [PSCustomObject]@{ Output = '1'; ExitStatus = 0; Error = '' }
                }
                'systemctl is-active' {
                    [PSCustomObject]@{ Output = 'active'; ExitStatus = 0; Error = '' }
                }
                'nft list ruleset' {
                    [PSCustomObject]@{
                        Output = @(
                            'table inet filter {',
                            '  chain forward {',
                            '    iifname "priv0" oifname "ext0" accept',
                            '  }',
                            '}',
                            'table ip nat {',
                            '  chain postrouting {',
                            '    oifname "ext0" masquerade',
                            '  }',
                            '}'
                        )
                        ExitStatus = 0; Error = ''
                    }
                }
                'ip -4 -o addr show dev priv0' {
                    [PSCustomObject]@{
                        Output = '2: priv0    inet 10.10.0.1/24 scope global priv0'
                        ExitStatus = 0; Error = ''
                    }
                }
                default { [PSCustomObject]@{ Output = ''; ExitStatus = 0; Error = '' } }
            }
        }
    }

    $script:Client = [PSCustomObject]@{ Connected = $true }

    function Invoke-AssertRouterReady {
        Assert-RouterReady -SshClient $script:Client -VmName 'router-e2e' `
            -PrivateIpAddress '10.10.0.1'
    }
}

Describe 'Assert-RouterReady' {

    Context 'fully-ready router' {

        It 'returns silently when forwarding, services, NAT rules and priv0 are all good' {
            Set-HappyRouterMock
            { Invoke-AssertRouterReady } | Should -Not -Throw
        }

        It 'queries systemctl is-active for every required service' {
            Set-HappyRouterMock
            Invoke-AssertRouterReady
            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -eq 'systemctl is-active nftables.service'
            } -Times 1 -Exactly
            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -eq 'systemctl is-active dnsmasq.service'
            } -Times 1 -Exactly
        }
    }

    Context 'IPv4 forwarding' {

        It 'throws when net.ipv4.ip_forward is not 1' {
            Set-HappyRouterMock
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{ Output = '0'; ExitStatus = 0; Error = '' }
            } -ParameterFilter { $Command -eq 'sysctl -n net.ipv4.ip_forward' }

            { Invoke-AssertRouterReady } |
                Should -Throw -ExpectedMessage "*ip_forward*is '0'*"
        }

        It 'throws when the sysctl probe itself fails' {
            Set-HappyRouterMock
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{ Output = ''; ExitStatus = 1; Error = 'permission denied' }
            } -ParameterFilter { $Command -eq 'sysctl -n net.ipv4.ip_forward' }

            { Invoke-AssertRouterReady } |
                Should -Throw -ExpectedMessage "*sysctl on 'router-e2e' failed*"
        }
    }

    Context 'required services active' {

        It 'throws naming the failing unit when is-active reports inactive' {
            # The 2026-06 dnsmasq case: bind race left it 'inactive'.
            Set-HappyRouterMock
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{ Output = 'inactive'; ExitStatus = 3; Error = '' }
            } -ParameterFilter { $Command -eq 'systemctl is-active dnsmasq.service' }
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{
                    Output = "Active: inactive (dead)`nFailed to create listening socket for 10.10.0.1"
                    ExitStatus = 3; Error = ''
                }
            } -ParameterFilter { $Command -like 'systemctl status*dnsmasq.service*' }

            { Invoke-AssertRouterReady } |
                Should -Throw -ExpectedMessage "*dnsmasq.service*router-e2e*inactive*"
        }

        It 'includes systemctl status output in the throw so the operator sees why' {
            Set-HappyRouterMock
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{ Output = 'failed'; ExitStatus = 3; Error = '' }
            } -ParameterFilter { $Command -eq 'systemctl is-active dnsmasq.service' }
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{
                    Output = 'Failed to create listening socket: Cannot assign requested address'
                    ExitStatus = 3; Error = ''
                }
            } -ParameterFilter { $Command -like 'systemctl status*dnsmasq.service*' }

            { Invoke-AssertRouterReady } |
                Should -Throw -ExpectedMessage "*Cannot assign requested address*"
        }

        It 'treats a trailing newline in is-active output the same as no newline' {
            # Renci.SshNet sometimes returns output with a trailing newline.
            Set-HappyRouterMock
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{ Output = "active`n"; ExitStatus = 0; Error = '' }
            } -ParameterFilter { $Command -like 'systemctl is-active*' }

            { Invoke-AssertRouterReady } | Should -Not -Throw
        }
    }

    Context 'NAT + FORWARD rules' {

        It 'throws when the MASQUERADE rule on ext0 is missing' {
            Set-HappyRouterMock
            Mock Invoke-SshClientCommand {
                # FORWARD rule present, MASQUERADE absent.
                [PSCustomObject]@{
                    Output = 'iifname "priv0" oifname "ext0" accept'
                    ExitStatus = 0; Error = ''
                }
            } -ParameterFilter { $Command -eq 'sudo nft list ruleset' }

            { Invoke-AssertRouterReady } |
                Should -Throw -ExpectedMessage "*MASQUERADE on ext0 not found*"
        }

        It 'throws when the priv0 -> ext0 FORWARD rule is missing' {
            Set-HappyRouterMock
            Mock Invoke-SshClientCommand {
                # MASQUERADE present, FORWARD accept absent.
                [PSCustomObject]@{
                    Output = 'oifname "ext0" masquerade'
                    ExitStatus = 0; Error = ''
                }
            } -ParameterFilter { $Command -eq 'sudo nft list ruleset' }

            { Invoke-AssertRouterReady } |
                Should -Throw -ExpectedMessage "*FORWARD priv0 -> ext0 accept rule not found*"
        }
    }

    Context 'priv0 gateway IP' {

        It 'throws when priv0 does not carry the configured private IP' {
            Set-HappyRouterMock
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{
                    Output = '2: priv0    inet 10.99.0.1/24 scope global priv0'
                    ExitStatus = 0; Error = ''
                }
            } -ParameterFilter { $Command -eq 'ip -4 -o addr show dev priv0' }

            { Invoke-AssertRouterReady } |
                Should -Throw -ExpectedMessage "*priv0 on 'router-e2e' does not carry 10.10.0.1*"
        }
    }

    Context 'check ordering' {

        It 'checks forwarding before services - a forwarding failure short-circuits' {
            Set-HappyRouterMock
            $script:_probed = @()
            Mock Invoke-SshClientCommand {
                param($SshClient, $Command)
                $script:_probed += $Command
                if ($Command -eq 'sysctl -n net.ipv4.ip_forward') {
                    return [PSCustomObject]@{ Output = '0'; ExitStatus = 0; Error = '' }
                }
                [PSCustomObject]@{ Output = 'active'; ExitStatus = 0; Error = '' }
            }

            { Invoke-AssertRouterReady } | Should -Throw
            $script:_probed | Should -Not -Contain 'systemctl is-active nftables.service'
        }
    }
}
