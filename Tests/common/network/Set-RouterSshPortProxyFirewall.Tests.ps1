BeforeAll {
    # Stub the Windows Firewall + NetAdapter cmdlets so the source
    # can be dot-sourced and the calls Mocked per test.
    function Get-NetAdapter        { param($ErrorAction) }
    function Get-NetFirewallRule   { param([string] $DisplayName, $ErrorAction) }
    function New-NetFirewallRule {
        param(
            [string] $DisplayName,
            [string] $Direction,
            [int]    $LocalPort,
            [string] $Protocol,
            [string] $Action,
            [string] $InterfaceAlias
        )
    }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\common\network\Set-RouterSshPortProxyFirewall.ps1"

    function New-WslAdapter {
        [PSCustomObject]@{ Name = 'vEthernet (WSL (Hyper-V firewall))' }
    }
}

Describe 'Set-RouterSshPortProxyFirewall' {

    Context 'no WSL adapter present' {

        It 'skips the rule add without erroring' {
            # Real Get-NetAdapter emits nothing (empty pipeline) on
            # hosts without a WSL adapter - not $null. Match that.
            Mock Get-NetAdapter { }
            Mock New-NetFirewallRule { }

            Set-RouterSshPortProxyFirewall

            Should -Invoke New-NetFirewallRule -Times 0
        }
    }

    Context 'WSL adapter present, no existing rule' {

        It 'creates an inbound TCP allow rule scoped to the WSL adapter' {
            Mock Get-NetAdapter      { New-WslAdapter }
            Mock Get-NetFirewallRule { $null }
            Mock New-NetFirewallRule { }

            Set-RouterSshPortProxyFirewall

            Should -Invoke New-NetFirewallRule -Times 1 -Exactly -ParameterFilter {
                $Direction      -eq 'Inbound'     -and
                $LocalPort      -eq 2222          -and
                $Protocol       -eq 'TCP'         -and
                $Action         -eq 'Allow'       -and
                $InterfaceAlias -eq 'vEthernet (WSL (Hyper-V firewall))'
            }
        }

        It 'passes the operator-supplied ListenPort through' {
            Mock Get-NetAdapter      { New-WslAdapter }
            Mock Get-NetFirewallRule { $null }
            Mock New-NetFirewallRule { }

            Set-RouterSshPortProxyFirewall -ListenPort 8222

            Should -Invoke New-NetFirewallRule -Times 1 -Exactly -ParameterFilter {
                $LocalPort -eq 8222
            }
        }
    }

    Context 'WSL adapter present, matching rule already exists' {

        It 'skips the add (idempotency)' {
            Mock Get-NetAdapter      { New-WslAdapter }
            Mock Get-NetFirewallRule {
                [PSCustomObject]@{
                    DisplayName = 'Vm-Provisioner: WSL -> router SSH portproxy (TCP/2222)'
                }
            }
            Mock New-NetFirewallRule { }

            Set-RouterSshPortProxyFirewall

            Should -Invoke New-NetFirewallRule -Times 0
        }
    }
}
