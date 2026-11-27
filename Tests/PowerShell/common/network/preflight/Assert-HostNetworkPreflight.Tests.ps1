BeforeAll {

    # Stub Hyper-V / networking cmdlets unavailable outside a Hyper-V
    # host so the source file can be dot-sourced and the cmdlets mocked
    # per-test.
    function Get-VMSwitch { param([string]$Name, $ErrorAction) }
    function Get-NetAdapter { param([string]$Name, [switch]$Physical, $ErrorAction) }
    function Get-NetIPAddress { param([string]$InterfaceAlias, $AddressFamily, $ErrorAction) }
    function Get-NetRoute { param([string]$DestinationPrefix, $ErrorAction) }
    function Get-VMNetworkAdapter { param([switch]$All, $ErrorAction) }

    # Get-WirelessNetAdapter is the shared "which NICs are Wi-Fi" helper
    # the orchestrator now calls instead of an inline Get-NetAdapter
    # -Physical filter. Stub it here so the MAC checks can be driven
    # per-test independently of the vEthernet Get-NetAdapter lookup.
    function Get-WirelessNetAdapter { }

    # Stubs for the two check functions that moved to
    # Infrastructure.Network.Windows. Their own behavior has dedicated
    # tests in that module; here we only care about the orchestrator's
    # branching, so file-scope stubs let Pester Mock them per test.
    function Test-IcsDnsProxyReachable {
        param(
            [string] $DnsProbeTarget,
            [string] $LanAdapterName,
            [string] $WanAdapterName,
            [switch] $NoAutoRepair
        )
    }

    function Test-HostNetworkProfileSetting { param([string]$InterfaceAlias, [switch]$NoAutoRepair) }

    # The production loader, so the suite runs against the same set of
    # functions the entry points load. The checks, the pure adapter-IPv4
    # extractor and the findings helpers are real, not stubs: each has a
    # suite of its own, and what is under test HERE is that the orchestrator
    # feeds them the right host snapshot and consolidates what they return -
    # which a stub would fake away.
    $preflight = "$PSScriptRoot\..\..\..\..\..\hyper-v\ubuntu\PowerShell\common\network\preflight"

    . "$preflight\Import-PreflightFunctions.ps1"

    # The switch under test; Internal is the ICS topology.
    function New-VmSwitch {

        param([string] $SwitchType = 'Internal')

        [PSCustomObject]@{
            Name = 'ExternalSwitch-Shared'
            SwitchType = $SwitchType }
    }

    function New-IcsVNic {

        param([string] $Mac = '00-15-5D-00-BB-FB')

        [PSCustomObject]@{
            Name = 'vEthernet (ExternalSwitch-Shared)'
            Status = 'Up'
            MacAddress = $Mac
        }
    }

    # The host vNIC's address; the defaults are what ICS assigns.
    function New-VNicIp {

        param(
            [string] $Address = '192.168.137.1',
            [string] $PrefixOrigin = 'Manual'
        )

        [PSCustomObject]@{
            IPAddress = $Address
            PrefixLength = 24
            PrefixOrigin = $PrefixOrigin
        }
    }

    # The connected route to the host vNIC's own subnet.
    function New-VNicRoute {

        param([int] $InterfaceMetric = 15)

        [PSCustomObject]@{
            InterfaceAlias = 'vEthernet (ExternalSwitch-Shared)'
            RouteMetric = 256
            InterfaceMetric = $InterfaceMetric
        }
    }

    function New-WifiAdapter {

        param([string] $Mac = '44-A3-BB-BC-51-06')

        [PSCustomObject]@{
            Name = 'WiFi'
            InterfaceDescription = 'Killer Wi-Fi 7'
            MacAddress = $Mac
        }
    }

    # A VM's adapter as Get-VMNetworkAdapter reports it.
    function New-VmNetworkAdapter {

        param(
            [string] $SwitchName = 'ExternalSwitch-Shared',
            [string[]] $IpAddress = @()
        )

        [PSCustomObject]@{
            SwitchName = $SwitchName
            IPAddresses = $IpAddress
        }
    }

    # What Get-InternetRoute answers for a host with a route out.
    function New-InternetRoute {

        param(
            [string] $Alias,
            [string] $NextHop
        )

        [PSCustomObject]@{
            InterfaceAlias = $Alias
            NextHop = $NextHop
        }
    }

    function Initialize-HappyMocks {

        # Default = clean Internal+ICS setup, elevated session,
        # no VMs on switch, profile already Private, ICS DNS proxy
        # answering. Anything more interesting flips one mock.
        Mock Test-IsCurrentSessionElevated { $true }
        Mock Get-VMSwitch { New-VmSwitch }

        # Get-NetAdapter now only serves the vEthernet ($Name) lookup;
        # the physical-Wi-Fi lookup moved behind Get-WirelessNetAdapter.
        Mock Get-NetAdapter { New-IcsVNic }
        Mock Get-WirelessNetAdapter { @(New-WifiAdapter) }
        Mock Get-NetIPAddress { New-VNicIp }
        Mock Get-NetRoute { New-VNicRoute }
        Mock Get-VMNetworkAdapter { }

        # Internet traffic leaves via the Wi-Fi WAN adapter.
        Mock Get-InternetRoute {
            New-InternetRoute `
                -Alias 'WiFi' `
                -NextHop '172.16.0.1'
        }

        # The four NetworkWindows check functions are stubbed at
        # BeforeAll scope; Mock here so the orchestrator's calls
        # produce a "happy" finding by default. Tests that exercise
        # FAIL/auto-repair paths re-Mock them inline.
        Mock Test-HostNetworkProfileSetting {
            [PSCustomObject]@{
                Status = 'PASS'
                Label = 'vEthernet profile = Private'
                Detail = 'Current=Private. ICS DNS-In permitted.'
            }
        }

        Mock Test-IcsDnsProxyReachable {
            [PSCustomObject]@{
                Status = 'PASS'
                Label = "ICS DNS proxy answers at $DnsProbeTarget"
                Detail = 'Resolve-DnsName archive.ubuntu.com succeeded against the ICS gateway.'
            }
        }
    }
}

Describe 'Assert-HostNetworkPreflight' {

    Context 'clean Internal+ICS setup' {

        It 'returns without throwing when every check passes' {

            Initialize-HappyMocks

            { Assert-HostNetworkPreflight -SwitchName 'ExternalSwitch-Shared' } |
                Should -Not -Throw
        }

        It 'consults Get-VMSwitch with the requested switch name' {

            Initialize-HappyMocks

            Assert-HostNetworkPreflight -SwitchName 'ExternalSwitch-Shared'

            Should -Invoke Get-VMSwitch `
                -Times 1 `
                -Exactly `
                -ParameterFilter { $Name -eq 'ExternalSwitch-Shared' }
        }
    }

    Context 'non-elevated PowerShell session' {

        It 'throws with the elevation hint when the session is not admin' {

            # Without elevation, Hyper-V cmdlets silently return
            # nothing, so the script would otherwise misread it as
            # "switch missing". The elevation check fails first
            # with an actionable error.
            Initialize-HappyMocks

            Mock Test-IsCurrentSessionElevated { $false }

            { Assert-HostNetworkPreflight -SwitchName 'ExternalSwitch-Shared' } |
                Should -Throw -ExpectedMessage "*elevated PowerShell*"
        }

        It 'short-circuits all Hyper-V probes when not elevated' {

            Initialize-HappyMocks

            Mock Test-IsCurrentSessionElevated { $false }
            Mock Get-VMSwitch { throw 'should not be called' }
            Mock Get-NetAdapter { throw 'should not be called' }

            { Assert-HostNetworkPreflight -SwitchName 'ExternalSwitch-Shared' } |
                Should -Throw

            Should -Invoke Get-VMSwitch -Times 0
            Should -Invoke Get-NetAdapter -Times 0
        }
    }

    Context 'missing switch' {

        It 'throws with the missing-switch label in the message' {

            Initialize-HappyMocks

            Mock Get-VMSwitch { }

            { Assert-HostNetworkPreflight -SwitchName 'NoSuchSwitch' } |
                Should -Throw -ExpectedMessage "*NoSuchSwitch*"
        }

        It 'short-circuits downstream checks when the switch is missing' {

            Initialize-HappyMocks

            Mock Get-VMSwitch { }
            Mock Get-NetAdapter { throw 'should not be called' }
            Mock Get-NetIPAddress { throw 'should not be called' }

            { Assert-HostNetworkPreflight -SwitchName 'NoSuchSwitch' } |
                Should -Throw

            Should -Invoke Get-NetAdapter -Times 0
            Should -Invoke Get-NetIPAddress -Times 0
        }
    }

    Context 'host vNIC down or missing IPv4' {

        It 'throws when the vEthernet adapter is missing' {

            Initialize-HappyMocks

            # vEthernet lookup returns nothing; the Wi-Fi lookup
            # (Get-WirelessNetAdapter) still returns normally via the
            # happy mock.
            Mock Get-NetAdapter { $null }

            { Assert-HostNetworkPreflight -SwitchName 'ExternalSwitch-Shared' } |
                Should -Throw -ExpectedMessage "*Host vNIC*"
        }

        It 'throws when the vEthernet adapter is Disabled' {

            Initialize-HappyMocks

            Mock Get-NetAdapter {
                [PSCustomObject]@{
                    Name = 'vEthernet (ExternalSwitch-Shared)'
                    Status = 'Disabled'
                    MacAddress = '00-15-5D-00-BB-FB'
                }
            }

            { Assert-HostNetworkPreflight -SwitchName 'ExternalSwitch-Shared' } |
                Should -Throw -ExpectedMessage "*Disabled*"
        }

        It 'throws when the vEthernet has no IPv4 bound' {

            Initialize-HappyMocks
            Mock Get-NetIPAddress { }

            { Assert-HostNetworkPreflight -SwitchName 'ExternalSwitch-Shared' } |
                Should -Throw -ExpectedMessage "*has IPv4*"
        }
    }

    Context 'Internal switch sharing MAC with a WiFi adapter (stale config)' {

        It 'throws when the vEthernet MAC matches a physical WiFi MAC' {

            # Same MAC on both vEthernet and the WiFi adapter is the
            # exact stale-config signature - operator forgot to recreate
            # the switch as Internal after External -> ICS.
            $sharedMac = '44-A3-BB-BC-51-06'

            Initialize-HappyMocks

            Mock Get-NetAdapter { New-IcsVNic -Mac $sharedMac }
            Mock Get-WirelessNetAdapter { @(New-WifiAdapter -Mac $sharedMac) }

            { Assert-HostNetworkPreflight -SwitchName 'ExternalSwitch-Shared' } |
                Should -Throw -ExpectedMessage "*vEthernet MAC distinct*"
        }
    }

    Context 'External switch bridged to WiFi' {
        # External-on-WiFi MAC-translates every VM to the host's
        # WiFi MAC at the AP, which guarantees the duplicate-lease
        # collision we hit in the 2026-06 trip. Treated as a hard
        # FAIL: the provisioner must not silently continue into a
        # 10-min wait-for-SSH that ends in routing-loop confusion.

        It 'throws when External switch shares MAC with WiFi' {

            $sharedMac = '44-A3-BB-BC-51-06'

            Initialize-HappyMocks

            Mock Get-VMSwitch { New-VmSwitch -SwitchType 'External' }
            Mock Get-NetAdapter { New-IcsVNic -Mac $sharedMac }
            Mock Get-WirelessNetAdapter { @(New-WifiAdapter -Mac $sharedMac) }
            Mock Get-NetRoute { New-VNicRoute -InterfaceMetric 35 }

            Mock Get-NetIPAddress {
                New-VNicIp `
                    -Address '192.168.5.8' `
                    -PrefixOrigin 'Dhcp'
            }

            { Assert-HostNetworkPreflight -SwitchName 'ExternalSwitch-Shared' } |
                Should -Throw -ExpectedMessage "*External switch bridged to WiFi*"
        }

        It 'does not throw when External switch is bridged to a non-WiFi adapter' {

            # The same SwitchType=External but the vEthernet MAC does
            # not match any physical WiFi NIC - this is the wired
            # Ethernet bridge case and is the design-correct path.
            Initialize-HappyMocks
            Mock Get-VMSwitch { New-VmSwitch -SwitchType 'External' }

            # The bridged Ethernet adapter's MAC.
            Mock Get-NetAdapter { New-IcsVNic -Mac '00-11-22-33-44-55' }
            Mock Get-WirelessNetAdapter { @(New-WifiAdapter -Mac '44-A3-BB-BC-51-06') }
            Mock Get-NetRoute { New-VNicRoute -InterfaceMetric 25 }

            Mock Get-NetIPAddress {
                New-VNicIp `
                    -Address '192.168.1.10' `
                    -PrefixOrigin 'Dhcp'
            }

            { Assert-HostNetworkPreflight -SwitchName 'ExternalSwitch-Shared' } |
                Should -Not -Throw
        }
    }

    Context 'connected route missing' {

        It 'throws when no connected route exists for the host vNICs subnet' {

            Initialize-HappyMocks
            Mock Get-NetRoute { }

            { Assert-HostNetworkPreflight -SwitchName 'ExternalSwitch-Shared' } |
                Should -Throw -ExpectedMessage "*Connected route*"
        }

        It 'derives the subnet from the host vNIC IPv4 + PrefixLength' {

            Initialize-HappyMocks

            Assert-HostNetworkPreflight -SwitchName 'ExternalSwitch-Shared'

            Should -Invoke Get-NetRoute `
                -Times 1 `
                -Exactly `
                -ParameterFilter { $DestinationPrefix -eq '192.168.137.0/24' }
        }
    }

    Context 'IP collision between host vNIC and a VM' {

        It 'throws when a VM on the switch reports the same IP as the host vNIC' {

            # The WiFi-MAC-collision smoking gun: host vNIC and VM
            # both bound to the same address.
            Initialize-HappyMocks
            Mock Get-VMNetworkAdapter { @(New-VmNetworkAdapter -IpAddress '192.168.137.1') }

            { Assert-HostNetworkPreflight -SwitchName 'ExternalSwitch-Shared' } |
                Should -Throw -ExpectedMessage "*IP collision*"
        }

        It 'ignores VMs on other switches when looking for collisions' {

            Initialize-HappyMocks

            # The same IP, on a different switch.
            Mock Get-VMNetworkAdapter {
                @(New-VmNetworkAdapter `
                    -SwitchName 'PrivateSwitch-E2E' `
                    -IpAddress '192.168.137.1')
            }

            { Assert-HostNetworkPreflight -SwitchName 'ExternalSwitch-Shared' } |
                Should -Not -Throw
        }

        It 'tolerates a VM with no reported IPs (KVP daemon not up yet)' {

            Initialize-HappyMocks
            Mock Get-VMNetworkAdapter { @(New-VmNetworkAdapter) }

            { Assert-HostNetworkPreflight -SwitchName 'ExternalSwitch-Shared' } |
                Should -Not -Throw
        }

        It 'tolerates a VMNetworkAdapter object with no IPAddresses property at all (StrictMode-safe)' {

            # Real-world: stopped VMs and Management OS adapters
            # return VMNetworkAdapter objects that lack the
            # IPAddresses property entirely. Under
            # Set-StrictMode -Version Latest (set by the entry
            # script), accessing a missing property terminates
            # the script. Lock in the PSObject.Properties guard.
            Initialize-HappyMocks

            Mock Get-VMNetworkAdapter {
                @(
                    [PSCustomObject]@{
                        SwitchName = 'ExternalSwitch-Shared'
                        # NOTE: no IPAddresses property at all.
                    }
                )
            }

            Set-StrictMode -Version Latest

            try {
                { Assert-HostNetworkPreflight -SwitchName 'ExternalSwitch-Shared' } |
                    Should -Not -Throw
            }
            finally {
                Set-StrictMode -Off
            }
        }
    }

    Context 'internet route off the WAN adapter' {

        It 'throws when a VPN carries the internet route' {

            # Arrange
            Initialize-HappyMocks

            Mock Get-InternetRoute {
                New-InternetRoute `
                    -Alias 'ProtonVPN' `
                    -NextHop '0.0.0.0'
            }

            # Act
            $preflight = {
                Assert-HostNetworkPreflight `
                    -SwitchName 'ExternalSwitch-Shared' `
                    -WanAdapterName 'WiFi'
            }

            # Assert
            $preflight | Should -Throw -ExpectedMessage "*internet traffic via 'ProtonVPN'*"
        }

        It 'does not throw when the internet-route fault is allowed' {

            # Arrange
            Initialize-HappyMocks

            Mock Get-InternetRoute {
                New-InternetRoute `
                    -Alias 'ProtonVPN' `
                    -NextHop '0.0.0.0'
            }

            # Act
            $preflight = {
                Assert-HostNetworkPreflight `
                    -SwitchName 'ExternalSwitch-Shared' `
                    -WanAdapterName 'WiFi' `
                    -AllowInternetRouteFault
            }

            # Assert
            $preflight | Should -Not -Throw
        }

        It 'throws when the host has no route to the internet' {

            # Arrange
            Initialize-HappyMocks
            Mock Get-InternetRoute { }

            # Act
            $preflight = {
                Assert-HostNetworkPreflight `
                    -SwitchName 'ExternalSwitch-Shared' `
                    -WanAdapterName 'WiFi'
            }

            # Assert
            $preflight | Should -Throw -ExpectedMessage '*no route to the internet*'
        }

        # VMs on an External switch bridge straight onto the LAN; no ICS forwards
        # their traffic, so where the host's own route leaves says nothing.
        It 'skips the check on External switches' {

            # Arrange
            Initialize-HappyMocks
            Mock Get-VMSwitch { New-VmSwitch -SwitchType 'External' }

            # Act
            try {
                Assert-HostNetworkPreflight `
                    -SwitchName 'ExternalSwitch-Shared' `
                    -WanAdapterName 'WiFi'
            }
            catch {
                $null = $_
            }

            # Assert
            Should -Invoke Get-InternetRoute -Times 0
        }
    }

    Context 'multiple FAILs consolidated into one throw' {

        It 'reports every FAIL in the thrown message' {

            # Switch present but ALL downstream checks fail. Throw
            # message should list every FAIL with its Detail so the
            # operator does not have to re-run after each fix.
            Initialize-HappyMocks

            Mock Get-NetAdapter { $null }
            Mock Get-NetIPAddress { }
            Mock Get-NetRoute { }

            $failure = { Assert-HostNetworkPreflight -SwitchName 'ExternalSwitch-Shared' } |
                Should -Throw -PassThru

            # Headline + at least two of the four downstream FAIL labels.
            $failure.Exception.Message | Should -Match 'preflight failed'
            $failure.Exception.Message | Should -Match 'Host vNIC'
            $failure.Exception.Message | Should -Match 'has IPv4'
        }
    }

    # ------------------------------------------------------------------
    Context 'delegation to NetworkWindows checks' {
    # ------------------------------------------------------------------
    # The orchestrator's profile + ICS-DNS checks delegate to
    # Test-HostNetworkProfileSetting + Test-IcsDnsProxyReachable
    # respectively, both of which now ship in
    # Infrastructure.Network.Windows with their own dedicated tests.
    # Here we verify the orchestrator's call-site contract:
    #   - calls the delegate with the right args under the right
    #     conditions
    #   - threads the returned finding through Add-Finding so the
    #     overall PASS/FAIL verdict respects the delegate's verdict
    # Internal behavior (auto-repair, only-toggle-when-Public,
    # bounded retry) is covered in the NetworkWindows test suite.

        It 'calls Test-HostNetworkProfileSetting for the vEthernet alias on Internal switches' {

            Initialize-HappyMocks

            Assert-HostNetworkPreflight -SwitchName 'ExternalSwitch-Shared'

            Should -Invoke Test-HostNetworkProfileSetting `
                -Times 1 `
                -Exactly `
                -ParameterFilter { $InterfaceAlias -eq 'vEthernet (ExternalSwitch-Shared)' }
        }

        It 'skips Test-HostNetworkProfileSetting on External switches' {

            Initialize-HappyMocks
            Mock Get-VMSwitch { New-VmSwitch -SwitchType 'External' }

            try {
                Assert-HostNetworkPreflight -SwitchName 'ExternalSwitch-Shared'
            }
            catch {
                $null = $_
            }

            Should -Invoke Test-HostNetworkProfileSetting -Times 0
        }

        It 'threads the delegate FAIL finding into the orchestrator throw' {

            Initialize-HappyMocks

            Mock Test-HostNetworkProfileSetting {
                [PSCustomObject]@{
                    Status = 'FAIL'
                    Label = 'profile broken'
                    Detail = 'simulated failure'
                }
            }

            { Assert-HostNetworkPreflight -SwitchName 'ExternalSwitch-Shared' } |
                Should -Throw -ExpectedMessage '*profile broken*'
        }

        It 'calls Test-IcsDnsProxyReachable with the WAN + LAN + DnsProbeTarget' {

            Initialize-HappyMocks

            Assert-HostNetworkPreflight `
                -SwitchName 'ExternalSwitch-Shared' `
                -DnsProbeTarget '192.168.137.1' `
                -WanAdapterName 'WiFi'

            Should -Invoke Test-IcsDnsProxyReachable `
                -Times 1 `
                -Exactly `
                -ParameterFilter {
                    $DnsProbeTarget -eq '192.168.137.1' `
                        -and $LanAdapterName -eq 'vEthernet (ExternalSwitch-Shared)' `
                        -and $WanAdapterName -eq 'WiFi'
                }
        }

        It 'forwards -NoAutoRepair to Test-IcsDnsProxyReachable' {

            Initialize-HappyMocks

            Assert-HostNetworkPreflight `
                -SwitchName 'ExternalSwitch-Shared' `
                -DnsProbeTarget '192.168.137.1' `
                -WanAdapterName 'WiFi' `
                -NoAutoRepair

            Should -Invoke Test-IcsDnsProxyReachable `
                -Times 1 `
                -Exactly `
                -ParameterFilter { $NoAutoRepair.IsPresent }
        }

        It 'skips Test-IcsDnsProxyReachable when DnsProbeTarget is unset' {

            Initialize-HappyMocks

            Assert-HostNetworkPreflight -SwitchName 'ExternalSwitch-Shared'

            Should -Invoke Test-IcsDnsProxyReachable -Times 0
        }

        It 'threads the delegate FAIL finding into the orchestrator throw (DNS path)' {

            Initialize-HappyMocks

            Mock Test-IcsDnsProxyReachable {
                [PSCustomObject]@{
                    Status = 'FAIL'
                    Label = 'ICS DNS proxy broken'
                    Detail = 'simulated DNS probe failure'
                }
            }

            $preflight = {
                Assert-HostNetworkPreflight `
                    -SwitchName 'ExternalSwitch-Shared' `
                    -DnsProbeTarget '192.168.137.1' `
                    -WanAdapterName 'WiFi'
            }

            $preflight | Should -Throw -ExpectedMessage '*ICS DNS proxy broken*'
        }
    }
}
