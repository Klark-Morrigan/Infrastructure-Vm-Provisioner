BeforeAll {

    # Find-NetRoute is Windows-host-only; stub it so its two-object answer can
    # be driven per test.
    function Find-NetRoute { param([string]$RemoteIPAddress, $ErrorAction) }

    $net = "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\common\network"
    . "$net\Get-InternetRoute.ps1"
}

Describe 'Get-InternetRoute' {

    # Find-NetRoute answers with the source address first and the route second.
    It 'returns the route, not the source address that comes with it' {

        # Arrange
        Mock Find-NetRoute {

            [PSCustomObject]@{
                InterfaceAlias = 'WiFi'
                IPAddress = '172.16.0.20' }

            [PSCustomObject]@{
                InterfaceAlias = 'WiFi'
                NextHop = '172.16.0.1' }
        }

        # Act
        $route = Get-InternetRoute

        # Assert
        @($route).Count | Should -Be 1
        $route.InterfaceAlias | Should -Be 'WiFi'
        $route.NextHop | Should -Be '172.16.0.1'
    }

    It 'returns nothing when the host has no route out' {

        # Arrange
        Mock Find-NetRoute { }

        # Act
        $route = Get-InternetRoute

        # Assert
        $route | Should -BeNullOrEmpty
    }

    It 'asks about a public address' {

        # Arrange
        Mock Find-NetRoute { }

        # Act
        Get-InternetRoute

        # Assert
        Should -Invoke Find-NetRoute `
            -Times 1 `
            -Exactly `
            -ParameterFilter { $RemoteIPAddress -eq '1.1.1.1' }
    }
}
