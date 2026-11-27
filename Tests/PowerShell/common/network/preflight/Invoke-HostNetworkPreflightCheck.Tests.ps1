BeforeAll {

    # The preflight itself, the adapter lookup and the relay refresh each have
    # suites of their own; here they are stubbed so only this function's own
    # decisions are under test.
    function Assert-HostNetworkPreflight {
        param(
            [string] $SwitchName,
            [string] $DnsProbeTarget,
            [string] $WanAdapterName,
            [switch] $NoAutoRepair,
            [switch] $AllowInternetRouteFault
        )
    }

    function Resolve-WanAdapterName { param([string]$WanAdapterName) }
    function Set-RouterSshRelay { param([string]$ConnectAddress) }

    $net = "$PSScriptRoot\..\..\..\..\..\hyper-v\ubuntu\PowerShell\common\network"

    . "$net\Get-IcsHostAddress.ps1"
    . "$net\preflight\Invoke-HostNetworkPreflightCheck.ps1"
}

Describe 'Invoke-HostNetworkPreflightCheck' {

    BeforeEach {

        Mock Write-Host { }
        Mock Assert-HostNetworkPreflight { }
        Mock Set-RouterSshRelay { }
        Mock Resolve-WanAdapterName { 'WiFi' }
    }

    It 'runs the preflight read-only against the defaults and returns 0' {

        # Act
        $exitCode = Invoke-HostNetworkPreflightCheck

        # Assert
        $exitCode | Should -Be 0

        Should -Invoke Assert-HostNetworkPreflight `
            -Times 1 `
            -Exactly `
            -ParameterFilter {
                $SwitchName -eq 'ExternalSwitch-Shared' `
                    -and $DnsProbeTarget -eq '192.168.137.1' `
                    -and $WanAdapterName -eq 'WiFi' `
                    -and $NoAutoRepair.IsPresent `
                    -and -not $AllowInternetRouteFault.IsPresent
            }
    }

    It 'hands the adapter lookup the name the operator gave' {

        # Act
        Invoke-HostNetworkPreflightCheck -WanAdapterName 'Ethernet 2'

        # Assert
        Should -Invoke Resolve-WanAdapterName `
            -Times 1 `
            -Exactly `
            -ParameterFilter { $WanAdapterName -eq 'Ethernet 2' }
    }

    # An empty probe target is how an operator skips the DNS check.
    It 'passes an empty DNS probe target through rather than defaulting it' {

        # Act
        Invoke-HostNetworkPreflightCheck -DnsProbeTarget ''

        # Assert
        Should -Invoke Assert-HostNetworkPreflight `
            -Times 1 `
            -Exactly `
            -ParameterFilter { $DnsProbeTarget -eq '' }
    }

    It 'passes the internet-route override through' {

        # Act
        Invoke-HostNetworkPreflightCheck -AllowInternetRouteFault

        # Assert
        Should -Invoke Assert-HostNetworkPreflight `
            -Times 1 `
            -Exactly `
            -ParameterFilter { $AllowInternetRouteFault.IsPresent }
    }

    It 'leaves the relay alone on a read-only run' {

        # Act
        Invoke-HostNetworkPreflightCheck

        # Assert
        Should -Invoke Set-RouterSshRelay -Times 0
    }

    # The ICS toggle a repair may fire strands the relay, so a repair run
    # re-lays it.
    It 'allows repair and refreshes the relay to the router under -AutoRepair' {

        # Act
        $exitCode = Invoke-HostNetworkPreflightCheck -AutoRepair

        # Assert
        $exitCode | Should -Be 0

        Should -Invoke Assert-HostNetworkPreflight `
            -Times 1 `
            -Exactly `
            -ParameterFilter { -not $NoAutoRepair.IsPresent }

        Should -Invoke Set-RouterSshRelay `
            -Times 1 `
            -Exactly `
            -ParameterFilter { $ConnectAddress -eq '192.168.137.11' }
    }

    # Anything the re-lay emitted would otherwise join the return value and
    # turn the exit code into an array.
    It 'keeps the relay''s own output out of the exit code' {

        # Arrange
        Mock Set-RouterSshRelay { 'portproxy laid' }
        Mock Out-Host { }

        # Act
        $exitCode = Invoke-HostNetworkPreflightCheck -AutoRepair

        # Assert
        $exitCode | Should -Be 0
        @($exitCode).Count | Should -Be 1
    }

    It 'skips the relay refresh when no router address is given' {

        # Act
        Invoke-HostNetworkPreflightCheck `
            -AutoRepair `
            -RouterAddress ''

        # Assert
        Should -Invoke Set-RouterSshRelay -Times 0
    }

    It 'returns 1, prints the failure and leaves the relay alone when the preflight fails' {

        # Arrange
        Mock Assert-HostNetworkPreflight { throw 'Host network preflight failed (1 FAIL)' }

        # Act
        $exitCode = Invoke-HostNetworkPreflightCheck -AutoRepair

        # Assert
        $exitCode | Should -Be 1

        Should -Invoke Write-Host `
            -Times 1 `
            -Exactly `
            -ParameterFilter { $Object -eq 'Host network preflight failed (1 FAIL)' }

        Should -Invoke Set-RouterSshRelay -Times 0
    }
}
