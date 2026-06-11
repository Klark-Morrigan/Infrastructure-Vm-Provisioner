BeforeAll {
    # Pester needs the dependent command to exist before mocking; stub
    # at file scope so per-test Mocks attach.
    function Invoke-SshClientCommand { param($SshClient, $Command) }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\post\Assert-RouterServicesActive.ps1"
}

Describe 'Assert-RouterServicesActive' {

    It 'returns silently when every required service is active' {
        Mock Invoke-SshClientCommand {
            [PSCustomObject]@{ Output = 'active'; ExitStatus = 0 }
        }
        $client = [PSCustomObject]@{ Connected = $true }

        { Assert-RouterServicesActive -SshClient $client -VmName 'router-e2e' } |
            Should -Not -Throw
    }

    It 'queries systemctl is-active for every required service' {
        Mock Invoke-SshClientCommand {
            [PSCustomObject]@{ Output = 'active'; ExitStatus = 0 }
        }

        Assert-RouterServicesActive -SshClient ([PSCustomObject]@{}) -VmName 'router-e2e' `
            -RequiredServices @('nftables.service', 'dnsmasq.service')

        Should -Invoke Invoke-SshClientCommand -ParameterFilter {
            $Command -eq 'systemctl is-active nftables.service'
        } -Times 1 -Exactly

        Should -Invoke Invoke-SshClientCommand -ParameterFilter {
            $Command -eq 'systemctl is-active dnsmasq.service'
        } -Times 1 -Exactly
    }

    It 'throws naming the failing unit when is-active reports inactive' {
        # The 2026-06 dnsmasq case: bind race left it 'inactive'.
        Mock Invoke-SshClientCommand {
            param($SshClient, $Command)
            if ($Command -eq 'systemctl is-active dnsmasq.service') {
                return [PSCustomObject]@{ Output = 'inactive'; ExitStatus = 3 }
            }
            if ($Command -like 'systemctl status*dnsmasq.service*') {
                return [PSCustomObject]@{
                    Output = "Active: inactive (dead)`nFailed to create listening socket for 10.99.0.1"
                    ExitStatus = 3
                }
            }
            [PSCustomObject]@{ Output = 'active'; ExitStatus = 0 }
        }

        { Assert-RouterServicesActive -SshClient ([PSCustomObject]@{}) -VmName 'router-e2e' } |
            Should -Throw -ExpectedMessage "*dnsmasq.service*router-e2e*inactive*"
    }

    It 'includes systemctl status output in the throw so the operator sees why' {
        Mock Invoke-SshClientCommand {
            param($SshClient, $Command)
            if ($Command -eq 'systemctl is-active dnsmasq.service') {
                return [PSCustomObject]@{ Output = 'failed'; ExitStatus = 3 }
            }
            if ($Command -like 'systemctl status*dnsmasq.service*') {
                return [PSCustomObject]@{
                    Output = 'Failed to create listening socket: Cannot assign requested address'
                    ExitStatus = 3
                }
            }
            [PSCustomObject]@{ Output = 'active'; ExitStatus = 0 }
        }

        { Assert-RouterServicesActive -SshClient ([PSCustomObject]@{}) -VmName 'router-e2e' } |
            Should -Throw -ExpectedMessage "*Cannot assign requested address*"
    }

    It 'throws on the first failure - does not probe further units' {
        # Order matters: nftables comes first by default. If it fails,
        # we should NOT also probe dnsmasq.
        $script:_calls = @()
        Mock Invoke-SshClientCommand {
            param($SshClient, $Command)
            $script:_calls += $Command
            if ($Command -eq 'systemctl is-active nftables.service') {
                return [PSCustomObject]@{ Output = 'inactive'; ExitStatus = 3 }
            }
            [PSCustomObject]@{ Output = 'fallback'; ExitStatus = 0 }
        }

        { Assert-RouterServicesActive -SshClient ([PSCustomObject]@{}) -VmName 'router-e2e' } |
            Should -Throw

        $script:_calls | Should -Not -Contain 'systemctl is-active dnsmasq.service'
    }

    It 'treats a trailing newline in is-active output the same as no newline' {
        # Renci.SshNet sometimes returns the command output with a
        # trailing newline. The is-active comparison must match
        # after TrimEnd.
        Mock Invoke-SshClientCommand {
            [PSCustomObject]@{ Output = "active`n"; ExitStatus = 0 }
        }

        { Assert-RouterServicesActive -SshClient ([PSCustomObject]@{}) -VmName 'router-e2e' } |
            Should -Not -Throw
    }
}
