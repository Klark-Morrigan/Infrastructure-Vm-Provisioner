BeforeAll {
    # Hyper-V cmdlet, unavailable off a Hyper-V host.
    function Get-VMNetworkAdapter { param([switch] $All, $ErrorAction) }

    $net    = "$PSScriptRoot\..\..\..\..\..\..\hyper-v\ubuntu\PowerShell\common\network"
    $checks = "$net\preflight\checks"
    # The real IPv4 extractor: its StrictMode tolerance for adapters with no
    # IPAddresses property is part of what this check depends on.
    . "$net\Get-VmAdapterIPv4.ps1"
    . "$checks\Test-HostVmIpCollision.ps1"

    function New-Ip {
        param([string] $Address = '192.168.137.1')
        [PSCustomObject]@{ IPAddress = $Address }
    }
    function New-VmAdapter {
        param([string] $SwitchName = 'Sw', [string[]] $Addresses = @())
        [PSCustomObject]@{ SwitchName = $SwitchName; IPAddresses = $Addresses }
    }
}

Describe 'Test-HostVmIpCollision' {

    It 'fails when a VM on the switch reports the host address' {
        Mock Get-VMNetworkAdapter { @(New-VmAdapter -Addresses @('192.168.137.1')) }

        $finding = Test-HostVmIpCollision -SwitchName 'Sw' -Alias 'vEthernet (Sw)' `
                                          -IpAddress (New-Ip)

        $finding.Status | Should -Be 'FAIL'
        $finding.Detail | Should -BeLike '*both report 192.168.137.1*'
    }

    It 'offers the release stopgap quoted for the alias, and the durable fix' {
        Mock Get-VMNetworkAdapter { @(New-VmAdapter -Addresses @('192.168.137.1')) }

        $finding = Test-HostVmIpCollision -SwitchName 'Sw' -Alias 'vEthernet (Sw)' `
                                          -IpAddress (New-Ip)

        $finding.Detail | Should -BeLike '*ipconfig /release "vEthernet (Sw)"*'
        $finding.Detail | Should -BeLike '*switch to ICS*'
    }

    It 'passes and lists the VM addresses it compared against' {
        Mock Get-VMNetworkAdapter {
            @(New-VmAdapter -Addresses @('192.168.137.50', '192.168.137.51'))
        }

        $finding = Test-HostVmIpCollision -SwitchName 'Sw' -Alias 'vEthernet (Sw)' `
                                          -IpAddress (New-Ip)

        $finding.Status | Should -Be 'PASS'
        $finding.Detail | Should -BeLike '*192.168.137.50, 192.168.137.51*'
    }

    It 'ignores VMs attached to another switch' {
        # A duplicate address on a different switch is not a collision: the
        # host only steals traffic on the segment it shares.
        Mock Get-VMNetworkAdapter {
            @(New-VmAdapter -SwitchName 'OtherSwitch' -Addresses @('192.168.137.1'))
        }

        $finding = Test-HostVmIpCollision -SwitchName 'Sw' -Alias 'vEthernet (Sw)' `
                                          -IpAddress (New-Ip)

        $finding.Status | Should -Be 'PASS'
    }

    It 'tolerates a VM that reports no addresses yet (KVP daemon not up)' {
        Mock Get-VMNetworkAdapter { @(New-VmAdapter) }

        $finding = Test-HostVmIpCollision -SwitchName 'Sw' -Alias 'vEthernet (Sw)' `
                                          -IpAddress (New-Ip)

        $finding.Status | Should -Be 'PASS'
        $finding.Detail | Should -BeLike '*(0 IPs)*'
    }

    It 'stays silent without a host IPv4 - nothing can collide with nothing' {
        Mock Get-VMNetworkAdapter { @(New-VmAdapter -Addresses @('192.168.137.1')) }

        Test-HostVmIpCollision -SwitchName 'Sw' -Alias 'vEthernet (Sw)' -IpAddress $null |
            Should -BeNullOrEmpty
        Should -Invoke Get-VMNetworkAdapter -Times 0
    }
}
