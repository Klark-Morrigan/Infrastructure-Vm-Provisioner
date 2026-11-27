BeforeAll {

    $checks = "$PSScriptRoot\..\..\..\..\..\..\hyper-v\ubuntu\PowerShell\common\network\preflight\checks"
    . "$checks\Test-InternetRouteThroughWan.ps1"

    # The route half of what Find-NetRoute returns for a public address.
    function New-InternetRoute {

        param(
            [string] $Alias = 'WiFi',
            [string] $NextHop = '172.16.0.1'
        )

        [PSCustomObject]@{
            InterfaceAlias = $Alias
            NextHop = $NextHop }
    }
}

Describe 'Test-InternetRouteThroughWan' {

    It 'passes when internet traffic leaves via the WAN adapter, naming the next hop' {

        # Arrange
        $route = New-InternetRoute

        # Act
        $finding = Test-InternetRouteThroughWan `
            -WanAdapterName 'WiFi' `
            -InternetRoute $route

        # Assert
        $finding.Status | Should -Be 'PASS'
        $finding.Label | Should -Be "Internet route leaves via WAN adapter 'WiFi'"
        $finding.Detail | Should -Be 'next hop 172.16.0.1'
    }

    # A VPN that holds the default route takes the traffic ICS forwards, while the
    # host itself stays online - so nothing else in the preflight notices.
    It 'fails when internet traffic leaves via another adapter, naming both fixes and the override' {

        # Arrange
        $route = New-InternetRoute `
            -Alias 'ProtonVPN' `
            -NextHop '0.0.0.0'

        $expectedDetail =
            "Windows sends internet traffic via 'ProtonVPN', so ICS cannot carry the VMs' traffic out. " +
            "A VPN: disconnect it. Another adapter: share that one through ICS instead. " +
            "A false positive: re-run with -AllowOtherInternetRoute."

        # Act
        $finding = Test-InternetRouteThroughWan `
            -WanAdapterName 'WiFi' `
            -InternetRoute $route

        # Assert
        $finding.Status | Should -Be 'FAIL'
        $finding.Detail | Should -Be $expectedDetail
    }

    It 'warns instead of failing when another adapter is allowed' {

        # Arrange
        $route = New-InternetRoute `
            -Alias 'ProtonVPN' `
            -NextHop '0.0.0.0'

        $expectedDetail =
            "Windows sends internet traffic via 'ProtonVPN'. " +
            "Allowed by -AllowOtherInternetRoute, so VM egress may fail."

        # Act
        $finding = Test-InternetRouteThroughWan `
            -WanAdapterName 'WiFi' `
            -InternetRoute $route `
            -AllowOtherInternetRoute

        # Assert
        $finding.Status | Should -Be 'WARN'
        $finding.Detail | Should -Be $expectedDetail
    }

    It 'matches the adapter name regardless of case' {

        # Arrange
        $route = New-InternetRoute -Alias 'wifi'

        # Act
        $finding = Test-InternetRouteThroughWan `
            -WanAdapterName 'WiFi' `
            -InternetRoute $route

        # Assert
        $finding.Status | Should -Be 'PASS'
    }

    It 'fails when the host has no route to the internet' {

        # Arrange
        $expectedDetail =
            "The host has no route to the internet, so neither it nor the VMs can reach out. " +
            "Connect 'WiFi' to a network. " +
            "A false positive: re-run with -AllowOtherInternetRoute."

        # Act
        $finding = Test-InternetRouteThroughWan `
            -WanAdapterName 'WiFi' `
            -InternetRoute $null

        # Assert
        $finding.Status | Should -Be 'FAIL'
        $finding.Detail | Should -Be $expectedDetail
    }

    It 'warns instead of failing on no route when another route is allowed' {

        # Arrange
        $expectedDetail =
            "The host has no route to the internet. " +
            "Allowed by -AllowOtherInternetRoute, so VM egress may fail."

        # Act
        $finding = Test-InternetRouteThroughWan `
            -WanAdapterName 'WiFi' `
            -InternetRoute $null `
            -AllowOtherInternetRoute

        # Assert
        $finding.Status | Should -Be 'WARN'
        $finding.Detail | Should -Be $expectedDetail
    }

    # Without the WAN adapter there is nothing to compare the route with, but a
    # skipped check stays visible rather than passing quietly.
    It 'warns that it was skipped when no WAN adapter is named' {

        # Arrange
        $route = New-InternetRoute

        # Act
        $finding = Test-InternetRouteThroughWan `
            -WanAdapterName '' `
            -InternetRoute $route

        # Assert
        $finding.Status | Should -Be 'WARN'
        $finding.Label | Should -Be 'Internet route leaves via the WAN adapter'
        $finding.Detail | Should -Be 'Skipped: no WAN adapter named. Pass -WanAdapterName to compare.'
    }
}
