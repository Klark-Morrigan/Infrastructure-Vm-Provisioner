BeforeAll {
    $checks = "$PSScriptRoot\..\..\..\..\..\..\hyper-v\ubuntu\PowerShell\common\network\preflight\checks"
    . "$checks\Test-SwitchMacExpectation.ps1"

    $script:WifiMac = '44-A3-BB-BC-51-06'
    $script:VmMac   = '00-15-5D-00-BB-FB'

    function New-Switch { param([string] $Type) [PSCustomObject]@{ SwitchType = $Type } }
    function New-VNic   { param([string] $Mac) [PSCustomObject]@{ MacAddress = $Mac } }
    function New-Wifi   {
        param([string] $Mac = $script:WifiMac)
        [PSCustomObject]@{ Name = 'WiFi'; MacAddress = $Mac }
    }
    function New-Ip {
        param([string] $Address = '192.168.137.1')
        [PSCustomObject]@{ IPAddress = $Address }
    }
}

Describe 'Test-SwitchMacExpectation' {

    Context 'Internal switch' {

        It 'fails on a MAC shared with a Wi-Fi NIC, naming the adapter' {
            # On Internal the host gets its own private L3 via ICS, so a shared
            # MAC means the switch was never recreated after the migration.
            $findings = @(Test-SwitchMacExpectation `
                -Switch (New-Switch 'Internal') `
                -Adapter (New-VNic $script:WifiMac) `
                -IpAddress (New-Ip) `
                -WirelessAdapter @(New-Wifi))

            $mac = $findings | Where-Object Label -like '*MAC distinct*'
            $mac.Status | Should -Be 'FAIL'
            $mac.Detail | Should -BeLike "*'WiFi'*"
        }

        It 'passes on a distinct MAC' {
            $findings = @(Test-SwitchMacExpectation `
                -Switch (New-Switch 'Internal') `
                -Adapter (New-VNic $script:VmMac) `
                -IpAddress (New-Ip) `
                -WirelessAdapter @(New-Wifi))

            ($findings | Where-Object Label -like '*MAC distinct*').Status |
                Should -Be 'PASS'
        }

        It 'passes the ICS host IP when it is the hardcoded .1' {
            $findings = @(Test-SwitchMacExpectation `
                -Switch (New-Switch 'Internal') `
                -Adapter (New-VNic $script:VmMac) `
                -IpAddress (New-Ip) `
                -WirelessAdapter @(New-Wifi))

            ($findings | Where-Object Label -like '*ICS host IP*').Status |
                Should -Be 'PASS'
        }

        It 'warns - not fails - on a customised host IP' {
            # A registry-customised ICS range is legitimate, so this must not
            # abort a provisioning run.
            $findings = @(Test-SwitchMacExpectation `
                -Switch (New-Switch 'Internal') `
                -Adapter (New-VNic $script:VmMac) `
                -IpAddress (New-Ip '10.0.0.1') `
                -WirelessAdapter @(New-Wifi))

            $ip = $findings | Where-Object Label -like '*ICS host IP*'
            $ip.Status | Should -Be 'WARN'
            $ip.Detail | Should -BeLike '*Got 10.0.0.1*'
        }

        It 'says nothing about the host IP when there is none to judge' {
            $findings = @(Test-SwitchMacExpectation `
                -Switch (New-Switch 'Internal') `
                -Adapter (New-VNic $script:VmMac) `
                -IpAddress $null `
                -WirelessAdapter @(New-Wifi))

            $findings | Where-Object Label -like '*ICS host IP*' |
                Should -BeNullOrEmpty
        }
    }

    Context 'External switch' {

        It 'fails on a MAC shared with a Wi-Fi NIC and points at Internal + ICS' {
            $findings = @(Test-SwitchMacExpectation `
                -Switch (New-Switch 'External') `
                -Adapter (New-VNic $script:WifiMac) `
                -IpAddress (New-Ip '192.168.5.8') `
                -WirelessAdapter @(New-Wifi))

            $findings.Count  | Should -Be 1
            $findings.Status | Should -Be 'FAIL'
            $findings.Detail | Should -BeLike '*same DHCP lease*'
            $findings.Detail | Should -BeLike '*Internal + enable Windows ICS*'
        }

        It 'is silent when bridged to a non-wireless adapter' {
            # External over Ethernet is a perfectly good setup; only the
            # Wi-Fi MAC-translation case is a problem.
            $findings = @(Test-SwitchMacExpectation `
                -Switch (New-Switch 'External') `
                -Adapter (New-VNic '00-11-22-33-44-55') `
                -IpAddress (New-Ip '192.168.1.10') `
                -WirelessAdapter @(New-Wifi))

            $findings.Count | Should -Be 0
        }
    }

    Context 'any other switch type' {

        It 'warns that a Private switch orphans its VMs' {
            $findings = @(Test-SwitchMacExpectation `
                -Switch (New-Switch 'Private') `
                -Adapter (New-VNic $script:VmMac) `
                -IpAddress (New-Ip) `
                -WirelessAdapter @(New-Wifi))

            $findings.Count  | Should -Be 1
            $findings.Status | Should -Be 'WARN'
            $findings.Detail | Should -BeLike '*orphan VMs*'
        }
    }

    Context 'host with no wireless NIC' {

        It 'skips the MAC comparison entirely rather than erroring' {
            # Every MAC verdict here is about Wi-Fi; with no wireless adapter
            # there is nothing to compare against.
            $findings = @(Test-SwitchMacExpectation `
                -Switch (New-Switch 'Internal') `
                -Adapter (New-VNic $script:VmMac) `
                -IpAddress (New-Ip) `
                -WirelessAdapter @())

            $findings | Where-Object Label -like '*MAC distinct*' |
                Should -BeNullOrEmpty
        }

        It 'reports no External bridging problem either' {
            $findings = @(Test-SwitchMacExpectation `
                -Switch (New-Switch 'External') `
                -Adapter (New-VNic $script:WifiMac) `
                -IpAddress (New-Ip) `
                -WirelessAdapter @())

            $findings.Count | Should -Be 0
        }
    }
}
