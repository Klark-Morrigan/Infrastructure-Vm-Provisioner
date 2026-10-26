BeforeAll {
    $checks = "$PSScriptRoot\..\..\..\..\..\..\hyper-v\ubuntu\PowerShell\common\network\preflight\checks"
    . "$checks\Test-HostVNicReady.ps1"

    function New-VNic {
        param([string] $Status = 'Up', [string] $Mac = '00-15-5D-00-BB-FB')
        [PSCustomObject]@{ Status = $Status; MacAddress = $Mac }
    }
    function New-Ip {
        [PSCustomObject]@{
            IPAddress    = '192.168.137.1'
            PrefixLength = 24
            PrefixOrigin = 'Manual'
        }
    }
}

Describe 'Test-HostVNicReady' {

    # Two findings every time: the adapter and its address fail for different
    # reasons and are fixed differently, so collapsing them into one verdict
    # would lose which of the two the operator has to act on.
    It 'always reports on both the adapter and the address' {
        $findings = @(Test-HostVNicReady -Alias 'vEthernet (Sw)' `
                                         -Adapter (New-VNic) -IpAddress (New-Ip))

        $findings.Count | Should -Be 2
    }

    Context 'adapter healthy' {

        It 'passes with the MAC, which check 3 then judges' {
            $findings = @(Test-HostVNicReady -Alias 'vEthernet (Sw)' `
                                             -Adapter (New-VNic) -IpAddress (New-Ip))

            $findings[0].Status | Should -Be 'PASS'
            $findings[0].Detail | Should -Be 'MAC=00-15-5D-00-BB-FB'
        }
    }

    Context 'adapter missing or down' {

        It 'fails with the switch-creation hint when absent' {
            $findings = @(Test-HostVNicReady -Alias 'vEthernet (Sw)' `
                                             -Adapter $null -IpAddress $null)

            $findings[0].Status | Should -Be 'FAIL'
            $findings[0].Detail | Should -BeLike '*Did switch creation finish?*'
        }

        It 'fails with the actual status when not Up' {
            $findings = @(Test-HostVNicReady -Alias 'vEthernet (Sw)' `
                                             -Adapter (New-VNic -Status 'Disabled') `
                                             -IpAddress (New-Ip))

            $findings[0].Status | Should -Be 'FAIL'
            $findings[0].Detail | Should -BeLike '*Status=Disabled*'
        }
    }

    Context 'IPv4 binding' {

        It 'passes with address, prefix and origin' {
            $findings = @(Test-HostVNicReady -Alias 'vEthernet (Sw)' `
                                             -Adapter (New-VNic) -IpAddress (New-Ip))

            $findings[1].Status | Should -Be 'PASS'
            $findings[1].Detail | Should -Be '192.168.137.1/24 (Manual)'
        }

        It 'fails naming ICS and DHCP as the two causes' {
            $findings = @(Test-HostVNicReady -Alias 'vEthernet (Sw)' `
                                             -Adapter (New-VNic) -IpAddress $null)

            $findings[1].Status | Should -Be 'FAIL'
            $findings[1].Detail | Should -BeLike '*ICS may have flipped off*'
            $findings[1].Detail | Should -BeLike '*DHCP has not bound*'
        }

        It 'still reports the address when the adapter itself is missing' {
            # Both halves of the picture in one run: an operator who only saw
            # "vEthernet missing" would not know the address was gone too.
            $findings = @(Test-HostVNicReady -Alias 'vEthernet (Sw)' `
                                             -Adapter $null -IpAddress $null)

            $findings.Count     | Should -Be 2
            $findings[1].Status | Should -Be 'FAIL'
        }
    }
}
