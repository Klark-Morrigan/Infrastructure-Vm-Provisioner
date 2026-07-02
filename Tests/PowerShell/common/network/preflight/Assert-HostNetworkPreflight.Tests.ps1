BeforeAll {
    # Stub Hyper-V / networking cmdlets unavailable outside a Hyper-V
    # host so the source file can be dot-sourced and the cmdlets mocked
    # per-test.
    function Get-VMSwitch              { param([string]$Name, $ErrorAction) }
    function Get-NetAdapter            { param([string]$Name, [switch]$Physical, $ErrorAction) }
    function Get-NetIPAddress          { param([string]$InterfaceAlias, $AddressFamily, $ErrorAction) }
    function Get-NetRoute              { param([string]$DestinationPrefix, $ErrorAction) }
    function Get-VMNetworkAdapter      { param([switch]$All, $ErrorAction) }
    # Get-WirelessNetAdapter is the shared "which NICs are Wi-Fi" helper
    # the orchestrator now calls instead of an inline Get-NetAdapter
    # -Physical filter. Stub it here so the MAC checks can be driven
    # per-test independently of the vEthernet Get-NetAdapter lookup.
    function Get-WirelessNetAdapter    { }
    # Stubs for the two check functions that moved to
    # Infrastructure.Network.Windows. Their own behavior has dedicated
    # tests in that module; here we only care about the orchestrator's
    # branching, so file-scope stubs let Pester Mock them per test.
    function Test-IcsDnsProxyReachable      { param([string]$DnsProbeTarget, [string]$LanAdapterName, [string]$WanAdapterName, [switch]$NoAutoRepair) }
    function Test-HostNetworkProfileSetting { param([string]$InterfaceAlias, [switch]$NoAutoRepair) }

    # Pure adapter-IPv4 extractor - dot-source the real one so the
    # IP-collision check's StrictMode-safety contract is exercised
    # end-to-end, not stubbed.
    $net       = "$PSScriptRoot\..\..\..\..\..\hyper-v\ubuntu\PowerShell\common\network"
    $preflight = "$net\preflight"
    $checks    = "$preflight\checks"
    . "$net\Get-VmAdapterIPv4.ps1"
    . "$checks\Test-IsCurrentSessionElevated.ps1"
    . "$preflight\Assert-PreflightFindings.ps1"
    . "$preflight\Assert-HostNetworkPreflight.ps1"

    function New-IcsVNic {
        param([string] $Mac = '00-15-5D-00-BB-FB')
        [PSCustomObject]@{
            Name        = 'vEthernet (ExternalSwitch-Shared)'
            Status      = 'Up'
            MacAddress  = $Mac
        }
    }
    function New-IcsIp {
        [PSCustomObject]@{
            IPAddress    = '192.168.137.1'
            PrefixLength = 24
            PrefixOrigin = 'Manual'
        }
    }
    function New-WifiAdapter {
        param([string] $Mac = '44-A3-BB-BC-51-06')
        [PSCustomObject]@{
            Name                 = 'WiFi'
            InterfaceDescription = 'Killer Wi-Fi 7'
            MacAddress           = $Mac
        }
    }

    function Initialize-HappyMocks {
        # Default = clean Internal+ICS setup, elevated session,
        # no VMs on switch, profile already Private, ICS DNS proxy
        # answering. Anything more interesting flips one mock.
        Mock Test-IsCurrentSessionElevated { $true }
        Mock Get-VMSwitch         { [PSCustomObject]@{ Name = 'ExternalSwitch-Shared'; SwitchType = 'Internal' } }
        # Get-NetAdapter now only serves the vEthernet ($Name) lookup;
        # the physical-Wi-Fi lookup moved behind Get-WirelessNetAdapter.
        Mock Get-NetAdapter         { New-IcsVNic }
        Mock Get-WirelessNetAdapter { @(New-WifiAdapter) }
        Mock Get-NetIPAddress     { New-IcsIp }
        Mock Get-NetRoute         {
            [PSCustomObject]@{
                InterfaceAlias  = 'vEthernet (ExternalSwitch-Shared)'
                RouteMetric     = 256
                InterfaceMetric = 15
            }
        }
        Mock Get-VMNetworkAdapter { }
        # The four NetworkWindows check functions are stubbed at
        # BeforeAll scope; Mock here so the orchestrator's calls
        # produce a "happy" finding by default. Tests that exercise
        # FAIL/auto-repair paths re-Mock them inline.
        Mock Test-HostNetworkProfileSetting {
            [PSCustomObject]@{
                Status = 'PASS'
                Label  = 'vEthernet profile = Private'
                Detail = 'Current=Private. ICS DNS-In permitted.'
            }
        }
        Mock Test-IcsDnsProxyReachable {
            [PSCustomObject]@{
                Status = 'PASS'
                Label  = "ICS DNS proxy answers at $DnsProbeTarget"
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

            Should -Invoke Get-VMSwitch -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'ExternalSwitch-Shared'
            }
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
            Mock Get-VMSwitch   { throw 'should not be called' }
            Mock Get-NetAdapter { throw 'should not be called' }

            { Assert-HostNetworkPreflight -SwitchName 'ExternalSwitch-Shared' } |
                Should -Throw

            Should -Invoke Get-VMSwitch   -Times 0
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
            Mock Get-VMSwitch     { }
            Mock Get-NetAdapter   { throw 'should not be called' }
            Mock Get-NetIPAddress { throw 'should not be called' }

            { Assert-HostNetworkPreflight -SwitchName 'NoSuchSwitch' } |
                Should -Throw

            Should -Invoke Get-NetAdapter   -Times 0
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
            Mock Get-NetAdapter         { New-IcsVNic -Mac $sharedMac }
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
            Mock Get-VMSwitch   { [PSCustomObject]@{ Name = 'ExternalSwitch-Shared'; SwitchType = 'External' } }
            Mock Get-NetAdapter         { New-IcsVNic -Mac $sharedMac }
            Mock Get-WirelessNetAdapter { @(New-WifiAdapter -Mac $sharedMac) }
            Mock Get-NetIPAddress {
                [PSCustomObject]@{
                    IPAddress    = '192.168.5.8'
                    PrefixLength = 24
                    PrefixOrigin = 'Dhcp'
                }
            }
            Mock Get-NetRoute {
                [PSCustomObject]@{
                    InterfaceAlias  = 'vEthernet (ExternalSwitch-Shared)'
                    RouteMetric     = 256
                    InterfaceMetric = 35
                }
            }

            { Assert-HostNetworkPreflight -SwitchName 'ExternalSwitch-Shared' } |
                Should -Throw -ExpectedMessage "*External switch bridged to WiFi*"
        }

        It 'does not throw when External switch is bridged to a non-WiFi adapter' {
            # The same SwitchType=External but the vEthernet MAC does
            # not match any physical WiFi NIC - this is the wired
            # Ethernet bridge case and is the design-correct path.
            Initialize-HappyMocks
            Mock Get-VMSwitch   { [PSCustomObject]@{ Name = 'ExternalSwitch-Shared'; SwitchType = 'External' } }
            Mock Get-NetAdapter         { New-IcsVNic -Mac '00-11-22-33-44-55' }   # bridged Ethernet MAC
            Mock Get-WirelessNetAdapter { @(New-WifiAdapter -Mac '44-A3-BB-BC-51-06') }
            Mock Get-NetIPAddress {
                [PSCustomObject]@{
                    IPAddress    = '192.168.1.10'
                    PrefixLength = 24
                    PrefixOrigin = 'Dhcp'
                }
            }
            Mock Get-NetRoute {
                [PSCustomObject]@{
                    InterfaceAlias  = 'vEthernet (ExternalSwitch-Shared)'
                    RouteMetric     = 256
                    InterfaceMetric = 25
                }
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
            $script:_routeQuery = $null
            Mock Get-NetRoute {
                $script:_routeQuery = $DestinationPrefix
                [PSCustomObject]@{
                    InterfaceAlias  = 'vEthernet (ExternalSwitch-Shared)'
                    RouteMetric     = 256
                    InterfaceMetric = 15
                }
            }

            Assert-HostNetworkPreflight -SwitchName 'ExternalSwitch-Shared'

            $script:_routeQuery | Should -Be '192.168.137.0/24'
        }
    }

    Context 'IP collision between host vNIC and a VM' {

        It 'throws when a VM on the switch reports the same IP as the host vNIC' {
            # The WiFi-MAC-collision smoking gun: host vNIC and VM
            # both bound to the same address.
            Initialize-HappyMocks
            Mock Get-VMNetworkAdapter {
                @(
                    [PSCustomObject]@{
                        SwitchName = 'ExternalSwitch-Shared'
                        IPAddresses = @('192.168.137.1')
                    }
                )
            }

            { Assert-HostNetworkPreflight -SwitchName 'ExternalSwitch-Shared' } |
                Should -Throw -ExpectedMessage "*IP collision*"
        }

        It 'ignores VMs on other switches when looking for collisions' {
            Initialize-HappyMocks
            Mock Get-VMNetworkAdapter {
                @(
                    [PSCustomObject]@{
                        SwitchName = 'PrivateSwitch-E2E'
                        IPAddresses = @('192.168.137.1')   # same IP, different switch
                    }
                )
            }

            { Assert-HostNetworkPreflight -SwitchName 'ExternalSwitch-Shared' } |
                Should -Not -Throw
        }

        It 'tolerates a VM with no reported IPs (KVP daemon not up yet)' {
            Initialize-HappyMocks
            Mock Get-VMNetworkAdapter {
                @(
                    [PSCustomObject]@{
                        SwitchName  = 'ExternalSwitch-Shared'
                        IPAddresses = @()
                    }
                )
            }

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
            } finally {
                Set-StrictMode -Off
            }
        }
    }

    Context 'multiple FAILs consolidated into one throw' {

        It 'reports every FAIL in the thrown message' {
            # Switch present but ALL downstream checks fail. Throw
            # message should list every FAIL with its Detail so the
            # operator does not have to re-run after each fix.
            Initialize-HappyMocks
            Mock Get-NetAdapter   { $null }
            Mock Get-NetIPAddress { }
            Mock Get-NetRoute     { }

            try {
                Assert-HostNetworkPreflight -SwitchName 'ExternalSwitch-Shared'
                throw 'expected an exception, got none'
            } catch {
                $msg = $_.Exception.Message
                # Headline + at least two of the four downstream FAIL labels.
                $msg | Should -Match 'preflight failed'
                $msg | Should -Match 'Host vNIC'
                $msg | Should -Match 'has IPv4'
            }
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

            Should -Invoke Test-HostNetworkProfileSetting -Times 1 -Exactly `
                -ParameterFilter {
                    $InterfaceAlias -eq 'vEthernet (ExternalSwitch-Shared)'
                }
        }

        It 'skips Test-HostNetworkProfileSetting on External switches' {
            Initialize-HappyMocks
            Mock Get-VMSwitch { [PSCustomObject]@{ Name = 'ExternalSwitch-Shared'; SwitchType = 'External' } }

            try { Assert-HostNetworkPreflight -SwitchName 'ExternalSwitch-Shared' } catch { $null = $_ }

            Should -Invoke Test-HostNetworkProfileSetting -Times 0
        }

        It 'threads the delegate FAIL finding into the orchestrator throw' {
            Initialize-HappyMocks
            Mock Test-HostNetworkProfileSetting {
                [PSCustomObject]@{
                    Status = 'FAIL'
                    Label  = 'profile broken'
                    Detail = 'simulated failure'
                }
            }

            { Assert-HostNetworkPreflight -SwitchName 'ExternalSwitch-Shared' } |
                Should -Throw -ExpectedMessage '*profile broken*'
        }

        It 'calls Test-IcsDnsProxyReachable with the WAN + LAN + DnsProbeTarget' {
            Initialize-HappyMocks

            Assert-HostNetworkPreflight `
                -SwitchName     'ExternalSwitch-Shared' `
                -DnsProbeTarget '192.168.137.1' `
                -WanAdapterName 'Wi-Fi'

            Should -Invoke Test-IcsDnsProxyReachable -Times 1 -Exactly `
                -ParameterFilter {
                    $DnsProbeTarget -eq '192.168.137.1'                       -and
                    $LanAdapterName -eq 'vEthernet (ExternalSwitch-Shared)'   -and
                    $WanAdapterName -eq 'Wi-Fi'
                }
        }

        It 'forwards -NoAutoRepair to Test-IcsDnsProxyReachable' {
            Initialize-HappyMocks

            Assert-HostNetworkPreflight `
                -SwitchName     'ExternalSwitch-Shared' `
                -DnsProbeTarget '192.168.137.1' `
                -WanAdapterName 'Wi-Fi' `
                -NoAutoRepair

            Should -Invoke Test-IcsDnsProxyReachable -Times 1 -Exactly `
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
                    Label  = 'ICS DNS proxy broken'
                    Detail = 'simulated DNS probe failure'
                }
            }

            { Assert-HostNetworkPreflight `
                -SwitchName     'ExternalSwitch-Shared' `
                -DnsProbeTarget '192.168.137.1' `
                -WanAdapterName 'Wi-Fi' } |
                Should -Throw -ExpectedMessage '*ICS DNS proxy broken*'
        }
    }
}
