BeforeAll {
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\common\network\Get-VmAdapterIPv4.ps1"

    function New-AdapterWithIps {
        param([string[]] $IPAddresses)
        [PSCustomObject]@{
            Name        = 'Network Adapter'
            SwitchName  = 'ExternalSwitch-Shared'
            MacAddress  = '020AB2FED200'
            IPAddresses = $IPAddresses
        }
    }
    function New-AdapterWithoutIpProperty {
        # Stopped VM / Management OS adapter shape.
        [PSCustomObject]@{
            Name       = 'Network Adapter'
            SwitchName = 'ExternalSwitch-Shared'
            MacAddress = '020AB2FED200'
        }
    }
}

Describe 'Get-VmAdapterIPv4' {

    It 'returns the IPv4 addresses from a single adapter' {
        $adapters = @(New-AdapterWithIps -IPAddresses @('192.168.137.50'))

        Get-VmAdapterIPv4 -Adapter $adapters |
            Should -Be '192.168.137.50'
    }

    It 'returns IPv4 addresses from multiple adapters in order' {
        $adapters = @(
            New-AdapterWithIps -IPAddresses @('192.168.137.50')
            New-AdapterWithIps -IPAddresses @('10.99.0.1')
        )

        $result = @(Get-VmAdapterIPv4 -Adapter $adapters)

        $result.Count | Should -Be 2
        $result[0]    | Should -Be '192.168.137.50'
        $result[1]    | Should -Be '10.99.0.1'
    }

    It 'drops IPv6 addresses' {
        $adapters = @(New-AdapterWithIps -IPAddresses @(
            '192.168.137.50',
            'fe80::a:b2ff:fefe:d200',
            '::1'
        ))

        Get-VmAdapterIPv4 -Adapter $adapters |
            Should -Be '192.168.137.50'
    }

    It 'tolerates an empty IPAddresses array' {
        $adapters = @(New-AdapterWithIps -IPAddresses @())

        @(Get-VmAdapterIPv4 -Adapter $adapters).Count | Should -Be 0
    }

    It 'tolerates adapters without an IPAddresses property under StrictMode' {
        # The strict-mode-safety guarantee - this is the property
        # that motivated the extraction. Stopped VMs / Management
        # OS adapters return objects without the property; reading
        # it under Set-StrictMode -Version Latest terminates the
        # script. The helper must not throw.
        $adapters = @(New-AdapterWithoutIpProperty)

        Set-StrictMode -Version Latest
        try {
            { Get-VmAdapterIPv4 -Adapter $adapters } | Should -Not -Throw
            @(Get-VmAdapterIPv4 -Adapter $adapters).Count | Should -Be 0
        } finally {
            Set-StrictMode -Off
        }
    }

    It 'tolerates mixed adapters where only some carry IPAddresses' {
        $adapters = @(
            New-AdapterWithIps -IPAddresses @('192.168.137.50')
            New-AdapterWithoutIpProperty
            New-AdapterWithIps -IPAddresses @('10.99.0.1')
        )

        $result = @(Get-VmAdapterIPv4 -Adapter $adapters)

        $result.Count | Should -Be 2
        $result       | Should -Contain '192.168.137.50'
        $result       | Should -Contain '10.99.0.1'
    }

    It 'returns an empty array for $null input' {
        @(Get-VmAdapterIPv4 -Adapter $null).Count | Should -Be 0
    }

    It 'returns an empty array for an empty input array' {
        @(Get-VmAdapterIPv4 -Adapter @()).Count | Should -Be 0
    }

    It 'accepts pipeline input' {
        $adapters = @(
            New-AdapterWithIps -IPAddresses @('192.168.137.50')
            New-AdapterWithIps -IPAddresses @('10.99.0.1')
        )

        $result = @($adapters | Get-VmAdapterIPv4)

        $result.Count | Should -Be 2
    }

    It 'rejects substring matches (e.g. "192.168.1.10/24")' {
        # The regex must be anchored - a CIDR with a trailing /24
        # is not a valid dotted-quad and must not slip through.
        $adapters = @(New-AdapterWithIps -IPAddresses @('192.168.1.10/24'))

        @(Get-VmAdapterIPv4 -Adapter $adapters).Count | Should -Be 0
    }
}
