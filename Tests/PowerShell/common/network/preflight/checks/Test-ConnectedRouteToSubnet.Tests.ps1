BeforeAll {
    # Get-NetRoute is Windows-host-only; stub it so the subnet arithmetic and
    # the alias filter can be driven deterministically.
    function Get-NetRoute { param([string] $DestinationPrefix, $ErrorAction) }

    $checks = "$PSScriptRoot\..\..\..\..\..\..\hyper-v\ubuntu\PowerShell\common\network\preflight\checks"
    . "$checks\Test-ConnectedRouteToSubnet.ps1"

    function New-Ip {
        param([string] $Address = '192.168.137.1', [int] $Prefix = 24)
        [PSCustomObject]@{ IPAddress = $Address; PrefixLength = $Prefix }
    }
    function New-Route {
        param([string] $Alias = 'vEthernet (Sw)', [int] $Metric = 256, [int] $IfMetric = 15)
        [PSCustomObject]@{
            InterfaceAlias  = $Alias
            RouteMetric     = $Metric
            InterfaceMetric = $IfMetric
        }
    }
}

Describe 'Test-ConnectedRouteToSubnet' {

    It 'derives the subnet from the address and prefix' {
        Mock Get-NetRoute { New-Route }

        Test-ConnectedRouteToSubnet -Alias 'vEthernet (Sw)' -IpAddress (New-Ip) | Out-Null

        Should -Invoke Get-NetRoute -Times 1 -Exactly `
            -ParameterFilter { $DestinationPrefix -eq '192.168.137.0/24' }
    }

    It 'passes with both metrics, which is what an operator compares' {
        Mock Get-NetRoute { New-Route }

        $finding = Test-ConnectedRouteToSubnet -Alias 'vEthernet (Sw)' -IpAddress (New-Ip)

        $finding.Status | Should -Be 'PASS'
        $finding.Detail | Should -Be 'metric 256+15'
    }

    It 'fails when no route exists, naming the wrong-interface consequence' {
        Mock Get-NetRoute { }

        $finding = Test-ConnectedRouteToSubnet -Alias 'vEthernet (Sw)' -IpAddress (New-Ip)

        $finding.Status | Should -Be 'FAIL'
        $finding.Detail | Should -BeLike '*WiFi default route*'
    }

    It 'ignores a route for the same subnet on a different interface' {
        # The route existing is not the point - it has to leave by the vNIC,
        # or VM-subnet traffic still goes out the Wi-Fi default gateway.
        Mock Get-NetRoute { New-Route -Alias 'Wi-Fi' }

        $finding = Test-ConnectedRouteToSubnet -Alias 'vEthernet (Sw)' -IpAddress (New-Ip)

        $finding.Status | Should -Be 'FAIL'
    }

    It 'reads the first route when several match' {
        Mock Get-NetRoute { @((New-Route -Metric 100), (New-Route -Metric 900)) }

        $finding = Test-ConnectedRouteToSubnet -Alias 'vEthernet (Sw)' -IpAddress (New-Ip)

        $finding.Detail | Should -Be 'metric 100+15'
    }

    It 'stays silent without an IPv4 - there is no subnet to route to' {
        Mock Get-NetRoute { New-Route }

        Test-ConnectedRouteToSubnet -Alias 'vEthernet (Sw)' -IpAddress $null |
            Should -BeNullOrEmpty
        Should -Invoke Get-NetRoute -Times 0
    }
}
