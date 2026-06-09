BeforeAll {
    # Stub all Hyper-V cmdlets unavailable outside a Hyper-V host.
    function New-VM                   { param($Name, $Generation, $MemoryStartupBytes, $VHDPath, $Path) }
    function Set-VMProcessor          { param($VMName, $Count) }
    function Get-VMHardDiskDrive      { param($VMName) }
    function Set-VMFirmware           { param($VMName, $EnableSecureBoot, $SecureBootTemplate, $FirstBootDevice) }
    function Add-VMDvdDrive           { param($VMName, $Path) }
    function Connect-VMNetworkAdapter { param($VMName, $Name, $SwitchName) }
    function Set-VMNetworkAdapter     { param($VMName, $Name, $StaticMacAddress) }
    function Add-VMNetworkAdapter     { param($VMName, $Name, $SwitchName, $StaticMacAddress) }
    function Start-VM                 { param($VMName) }
    function Get-VM                   { param($Name) }
    function Get-VMNetworkAdapter     { param($VMName) }
    function Get-VMDvdDrive           { param($VMName) }
    function Remove-VMDvdDrive        { param($VMName, $ControllerNumber, $ControllerLocation) }
    function Remove-Item              { param($Path, [switch]$Force) }
    function Test-Path                { param($Path) }

    # Stub the sub-step timer so creation tests stay focused on the
    # Hyper-V cmdlets. The stub invokes the action directly so mocks
    # inside still record their calls.
    function Invoke-WithSubStepTimer {
        param($Parent, $Name, [scriptblock] $Action)
        & $Action
    }

    # Serial-console capture stubs. The real cmdlets live in
    # Invoke-SerialConsoleCapture.ps1 and attach a named-pipe reader job
    # before Start-VM; here they are no-ops so the creation tests stay
    # focused on the Hyper-V dispatch and the finally-block cleanup. The
    # Start stub returns $null so the function-scoped $consoleCapture
    # variable carries a benign value into the wait-for-SSH sub-step's
    # finally, which then forwards it to Stop-SerialConsoleCapture.
    function Start-SerialConsoleCapture {
        param($VmName, $VmConfigPath, $Timestamp)
        $null
    }
    function Stop-SerialConsoleCapture {
        param($Capture)
    }

    # SSH polling stubs - the real cmdlets need Hyper-V networking
    # (Test-VmSshPort, Test-SshBanner) and Posh-SSH's Renci.SshNet
    # types (New-VmSshTunnel). Define them as no-ops here so Pester's
    # Mock layer can replace them in Initialize-HyperVMocks.
    function Test-VmSshPort {
        param([string] $IpAddress, [int] $Port = 22)
        $false
    }
    # Banner-read gate the wait-for-SSH loop runs AFTER a successful
    # Test-VmSshPort. Default to $true here so the canonical happy-path
    # tests (which mock Test-VmSshPort to $true) reach $sshReady=$true
    # without each test having to know about the new gate; tests that
    # care about the false-positive-through-tunnel path override locally.
    function Test-SshBanner {
        param([string] $IpAddress, [int] $Port = 22,
              [int] $TimeoutMilliseconds = 3000)
        $true
    }
    function New-VmSshTunnel {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSAvoidUsingPlainTextForPassword', 'JumpPassword')]
        param(
            [string] $TargetIp,
            [string] $JumpHostIp,
            [string] $JumpUsername,
            [string] $JumpPassword,
            [uint32] $TargetPort = 22,
            [TimeSpan] $JumpConnectTimeout = [TimeSpan]::FromSeconds(30)
        )
        $null
    }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\vm\create-vm.ps1"

    # Standard VM object satisfying all Invoke-VmCreation requirements.
    function New-TestVm {
        [PSCustomObject]@{
            vmName       = 'node-01'
            vmConfigPath = 'C:\a_VMs\Hyper-V\Config'
            username     = 'admin'
            ipAddress    = '192.168.1.10'
            cpuCount     = 2
            ramGB        = 4
            _vhdxPath    = 'C:\VMs\node-01\node-01.vhdx'
            _seedIsoPath = 'C:\VMs\node-01\node-01-seed.iso'
        }
    }

    # Router VM object - extra fields exercised by the dual-NIC branch.
    # Pester 5 only hoists function defs from BeforeAll (not Context),
    # so this lives at top-level alongside New-TestVm.
    function New-RouterTestVm {
        [PSCustomObject]@{
            vmName              = 'router-01'
            vmConfigPath        = 'C:\a_VMs\Hyper-V\Config'
            username            = 'admin'
            ipAddress           = '192.168.1.10'
            cpuCount            = 2
            ramGB               = 4
            _vhdxPath           = 'C:\VMs\router-01\router-01.vhdx'
            _seedIsoPath        = 'C:\VMs\router-01\router-01-seed.iso'
            kind                = 'router'
            externalSwitchName  = 'ExternalSwitch-Shared'
            privateSwitchName   = 'PrivateSwitch-Production'
            _externalMac        = '02aabbccdd00'
            _privateMac         = '02aabbccdd01'
        }
    }

    # DHCP-mode router VM - no ipAddress in its config (the upstream
    # NIC's address comes from the LAN's DHCP server, discovered via
    # Hyper-V KVP). Exercises the IP-discovery branch in wait-for-SSH.
    function New-DhcpRouterTestVm {
        [PSCustomObject]@{
            vmName              = 'router-01'
            vmConfigPath        = 'C:\a_VMs\Hyper-V\Config'
            username            = 'admin'
            cpuCount            = 2
            ramGB               = 4
            _vhdxPath           = 'C:\VMs\router-01\router-01.vhdx'
            _seedIsoPath        = 'C:\VMs\router-01\router-01-seed.iso'
            kind                = 'router'
            externalSwitchName  = 'ExternalSwitch-Shared'
            privateSwitchName   = 'PrivateSwitch-Production'
            _externalMac        = '02aabbccdd00'
            _privateMac         = '02aabbccdd01'
        }
    }

    # Standard DVD drive object returned by Get-VMDvdDrive.
    function New-TestDvdDrive {
        [PSCustomObject]@{
            Path               = 'C:\VMs\node-01\node-01-seed.iso'
            ControllerNumber   = 1
            ControllerLocation = 0
        }
    }

    # Sets up the Hyper-V creation stubs in their neutral no-op form.
    # Also sets up the finally-block stubs so cleanup always runs cleanly.
    function Initialize-HyperVMocks {
        Mock New-VM              { }
        Mock Set-VMProcessor     { }
        Mock Get-VMHardDiskDrive { [PSCustomObject]@{ Path = 'disk.vhdx' } }
        Mock Set-VMFirmware      { }
        Mock Add-VMDvdDrive      { }
        Mock Connect-VMNetworkAdapter { }
        Mock Set-VMNetworkAdapter     { }
        Mock Add-VMNetworkAdapter     { }
        Mock Start-VM            { }
        # Return Off state by default so the post-creation guard passes.
        Mock Get-VM              { [PSCustomObject]@{ State = 'Off' } }
        Mock Get-VMDvdDrive      { New-TestDvdDrive }
        Mock Remove-VMDvdDrive   { }
        Mock Test-Path           { $false }
        # IP discovery (KVP) defaults to "no adapters found" - router-
        # DHCP path either supplies its own override or hits the
        # discovery timeout cleanly. Workload + router-static tests
        # never trigger the discovery branch because their fixtures
        # carry ipAddress.
        Mock Get-VMNetworkAdapter { @() }
        # SSH polling: the real cmdlets reach Hyper-V networking and
        # Renci.SshNet; stub both. Test-VmSshPort returns $false so
        # the polling loop always falls through to the timeout path
        # (the deadline mock is what controls when the loop exits).
        # New-VmSshTunnel returns a tunnel-shaped object whose Dispose
        # method is a no-op, so the finally branch can call it without
        # touching the network.
        Mock Test-VmSshPort      { $false }
        # Banner-read gate is reached only when Test-VmSshPort is $true
        # (per-test override below). Default mock returns $true so the
        # canonical happy path is gated only by the TCP probe; tests
        # exercising the false-positive-through-tunnel branch override.
        Mock Test-SshBanner      { $true }
        $script:_tunnelDisposed  = 0
        Mock New-VmSshTunnel     {
            $obj = [PSCustomObject]@{
                LocalHost = '127.0.0.1'
                LocalPort = 12345
            }
            Add-Member -InputObject $obj -MemberType ScriptMethod `
                       -Name Dispose -Value {
                $script:_tunnelDisposed++
            }
            $obj
        }
    }

    # Makes the SSH polling loop body never execute by returning a
    # deadline in the past relative to what Get-Date returns on the
    # loop-condition check.
    #
    # The source's Get-Date sequence is:
    #   call 1 : Get-Date -Format ...   (per-run _diagTimestamp)
    #   call 2 : Get-Date               ($startTime, used for both the
    #                                    deadline calc and the elapsed
    #                                    print at the end)
    #   call 3+: while ((Get-Date) -lt $deadline)   (loop condition,
    #                                                 then once more for
    #                                                 the elapsed print)
    #
    # If the deadline call and the loop-condition call both see the same
    # instant T, the condition T < T+10min is true and the loop runs. To
    # prevent that, the first two calls return T (timestamp is irrelevant
    # to the test; deadline becomes T+10min) and every subsequent call
    # returns T+1hr (past the deadline, so the loop exits immediately).
    function Set-ExpiredDeadline {
        $script:_deadlineCallCount = 0
        Mock Get-Date {
            $script:_deadlineCallCount++
            if ($script:_deadlineCallCount -le 2) { [datetime]'2020-01-01' }
            else                                  { [datetime]'2020-01-01 01:00:00' }
        }
    }
}

Describe 'Invoke-VmCreation' {

    # ------------------------------------------------------------------
    Context 'VM creation parameters' {
    # ------------------------------------------------------------------

        It 'creates a Gen 2 VM with the correct name, RAM, VHDX, and config path' {
            Initialize-HyperVMocks
            Set-ExpiredDeadline

            { Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN' } |
                Should -Throw    # timeout throw - expected here

            Should -Invoke New-VM -Times 1 -Exactly -ParameterFilter {
                $Name               -eq 'node-01'                    -and
                $Generation         -eq 2                             -and
                $MemoryStartupBytes -eq (4 * 1GB)                    -and
                $VHDPath            -eq 'C:\VMs\node-01\node-01.vhdx' -and
                $Path               -eq 'C:\a_VMs\Hyper-V\Config'
            }
        }

        It 'sets the CPU count via Set-VMProcessor' {
            Initialize-HyperVMocks
            Set-ExpiredDeadline

            { Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN' } |
                Should -Throw

            Should -Invoke Set-VMProcessor -Times 1 -Exactly -ParameterFilter {
                $VMName -eq 'node-01' -and $Count -eq 2
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'Secure Boot configuration' {
    # ------------------------------------------------------------------
        # Ubuntu's shim bootloader requires MicrosoftUEFICertificateAuthority.
        # The default MicrosoftWindows template rejects third-party UEFI
        # bootloaders, causing a Secure Boot violation on first boot.

        It 'enables Secure Boot with the MicrosoftUEFICertificateAuthority template' {
            Initialize-HyperVMocks
            Set-ExpiredDeadline

            { Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN' } |
                Should -Throw

            Should -Invoke Set-VMFirmware -Times 1 -Exactly -ParameterFilter {
                $VMName             -eq 'node-01'                          -and
                $EnableSecureBoot   -eq 'On'                               -and
                $SecureBootTemplate -eq 'MicrosoftUEFICertificateAuthority'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'seed ISO attachment' {
    # ------------------------------------------------------------------

        It 'attaches the seed ISO as a DVD drive' {
            Initialize-HyperVMocks
            Set-ExpiredDeadline

            { Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN' } |
                Should -Throw

            Should -Invoke Add-VMDvdDrive -Times 1 -Exactly -ParameterFilter {
                $VMName -eq 'node-01' -and
                $Path   -eq 'C:\VMs\node-01\node-01-seed.iso'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'network adapter connection' {
    # ------------------------------------------------------------------

        It "connects the workload VM's NIC to the per-environment private switch" {
            # provision.ps1 now passes vm.privateSwitchName as -SwitchName
            # for workload VMs (feature 53 step 2 - no more singleton
            # VmLAN). Invoke-VmCreation itself is switch-name-agnostic;
            # this test pins that the value handed in is what reaches
            # Connect-VMNetworkAdapter.
            Initialize-HyperVMocks
            Set-ExpiredDeadline

            { Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'PrivateSwitch-Production' } |
                Should -Throw

            Should -Invoke Connect-VMNetworkAdapter -Times 1 -Exactly -ParameterFilter {
                $VMName     -eq 'node-01' -and
                $SwitchName -eq 'PrivateSwitch-Production'
            }
        }

        It 'does not pin a static MAC for a workload VM' {
            # Workload VMs let Hyper-V auto-assign MACs; the static-MAC
            # path is router-specific.
            Initialize-HyperVMocks
            Set-ExpiredDeadline

            { Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'PrivateSwitch-Production' } |
                Should -Throw

            Should -Invoke Set-VMNetworkAdapter -Times 0
            Should -Invoke Add-VMNetworkAdapter -Times 0
        }
    }

    # ------------------------------------------------------------------
    Context 'router VM dual-NIC attachment' {
    # ------------------------------------------------------------------
        # Router VMs (kind: router) get two NICs: the default Hyper-V
        # adapter connected to the external switch with its MAC pinned
        # to _externalMac, and a second adapter named 'Private' on the
        # privateSwitchName with its MAC pinned to _privateMac. The
        # seed ISO (Invoke-RouterSeedIsoGeneration) embeds these same
        # MACs in netplan's match blocks so the in-guest interfaces
        # come up against the right NIC.

        It 'connects the default NIC to the external switch (passed via -SwitchName)' {
            Initialize-HyperVMocks
            Set-ExpiredDeadline

            { Invoke-VmCreation -Vm (New-RouterTestVm) -SwitchName 'ExternalSwitch-Shared' } |
                Should -Throw

            Should -Invoke Connect-VMNetworkAdapter -Times 1 -Exactly -ParameterFilter {
                $VMName     -eq 'router-01' -and
                $SwitchName -eq 'ExternalSwitch-Shared'
            }
        }

        It 'pins the external NIC MAC via Set-VMNetworkAdapter' {
            Initialize-HyperVMocks
            Set-ExpiredDeadline

            { Invoke-VmCreation -Vm (New-RouterTestVm) -SwitchName 'ExternalSwitch-Shared' } |
                Should -Throw

            Should -Invoke Set-VMNetworkAdapter -Times 1 -Exactly -ParameterFilter {
                $VMName           -eq 'router-01' -and
                $Name             -eq 'Network Adapter' -and
                $StaticMacAddress -eq '02aabbccdd00'
            }
        }

        It 'adds a second NIC named Private on privateSwitchName with the private MAC' {
            Initialize-HyperVMocks
            Set-ExpiredDeadline

            { Invoke-VmCreation -Vm (New-RouterTestVm) -SwitchName 'ExternalSwitch-Shared' } |
                Should -Throw

            Should -Invoke Add-VMNetworkAdapter -Times 1 -Exactly -ParameterFilter {
                $VMName           -eq 'router-01' -and
                $Name             -eq 'Private' -and
                $SwitchName       -eq 'PrivateSwitch-Production' -and
                $StaticMacAddress -eq '02aabbccdd01'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'VM startup' {
    # ------------------------------------------------------------------

        It 'starts the VM after configuration' {
            Initialize-HyperVMocks
            Set-ExpiredDeadline

            { Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN' } |
                Should -Throw

            Should -Invoke Start-VM -Times 1 -Exactly -ParameterFilter {
                $VMName -eq 'node-01'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'post-creation state guard' {
    # ------------------------------------------------------------------
        # New-VM may silently fail when the target VHDX is locked by a
        # running leftover VM (Hyper-V can surface this as a warning rather
        # than a terminating error). A host auto-start policy can also
        # start a freshly-created VM before Set-VMFirmware runs. Either
        # way the VM is in a non-Off state right after New-VM returns, so
        # we check and throw before reaching Set-VMFirmware.

        It 'throws with an actionable message when the VM is not Off after creation' {
            Initialize-HyperVMocks
            Mock Get-VM { [PSCustomObject]@{ State = 'Running' } }

            { Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN' } |
                Should -Throw -ExpectedMessage '*Stop or remove the VM manually*'
        }

        It 'does not call Set-VMFirmware when the VM is not Off after creation' {
            Initialize-HyperVMocks
            Mock Get-VM { [PSCustomObject]@{ State = 'Running' } }

            { Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN' } |
                Should -Throw

            Should -Invoke Set-VMFirmware -Times 0
        }
    }

    # ------------------------------------------------------------------
    Context 'SSH polling - VM stops unexpectedly' {
    # ------------------------------------------------------------------
        # The loop checks VM state each iteration. If the VM is no longer
        # Running it throws immediately rather than waiting out the timeout,
        # avoiding a 10-minute wait when the VM has already crashed.

        It 'throws immediately when the VM state is not Running' {
            Initialize-HyperVMocks

            # Return a date far enough in the future that the deadline
            # (date + 10 min) does not overflow and the loop body executes
            # at least once before the state check fires.
            Mock Get-Date { [datetime]'2099-01-01' }
            Mock Get-VM   { [PSCustomObject]@{ State = 'Off' } }

            { Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN' } |
                Should -Throw -ExpectedMessage '*stopped unexpectedly*'
        }
    }

    # ------------------------------------------------------------------
    Context 'SSH polling - timeout' {
    # ------------------------------------------------------------------

        It 'throws when the deadline passes without SSH becoming reachable' {
            Initialize-HyperVMocks
            Set-ExpiredDeadline

            { Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN' } |
                Should -Throw -ExpectedMessage '*did not become reachable*'
        }
    }

    # ------------------------------------------------------------------
    Context 'SSH polling - router DHCP IP discovery' {
    # ------------------------------------------------------------------
        # DHCP-mode router VMs have no ipAddress in their config; the
        # wait-for-SSH sub-step discovers the actual ext0 IP via Hyper-V
        # KVP integration services before probing SSH and writes the
        # discovered value back onto the VM def so the workload tunnel
        # later (provision.ps1 step 7 references _RouterVm.ipAddress)
        # finds it via the same object.

        It 'queries Get-VMNetworkAdapter filtered to the external switch' {
            Initialize-HyperVMocks
            # Stateful Get-VM: Off for the post-creation guard, then
            # Running for the discovery + SSH loops. Mirrors the
            # pattern in the jump-host dispatch tests.
            $script:_getVmCallCount = 0
            Mock Get-VM {
                $script:_getVmCallCount++
                $state = if ($script:_getVmCallCount -eq 1) {
                    'Off'
                } else {
                    'Running'
                }
                [PSCustomObject]@{ State = $state }
            }
            # KVP returns the discovered IPv4 immediately.
            Mock Get-VMNetworkAdapter {
                @([PSCustomObject]@{
                    SwitchName  = 'ExternalSwitch-Shared'
                    IPAddresses = @('192.168.1.42', 'fe80::1234')
                })
            }
            # SSH probe succeeds on the FIRST iteration so the test
            # exits the loop cleanly without burning the full 10-min
            # budget. Side benefit: probeIp is set to the discovered
            # IP before this fires, so we can assert on it.
            $script:_probedIpAfterDiscovery = $null
            Mock Test-VmSshPort {
                param($IpAddress, $Port)
                $script:_probedIpAfterDiscovery = $IpAddress
                $true
            }

            Invoke-VmCreation -Vm (New-DhcpRouterTestVm) -SwitchName 'External'

            Should -Invoke Get-VMNetworkAdapter -ParameterFilter {
                $VMName -eq 'router-01'
            }
            $script:_probedIpAfterDiscovery | Should -Be '192.168.1.42'
        }

        It 'writes the discovered IP back onto the VM def as ipAddress' {
            Initialize-HyperVMocks
            $script:_getVmCallCount = 0
            Mock Get-VM {
                $script:_getVmCallCount++
                $state = if ($script:_getVmCallCount -eq 1) {
                    'Off'
                } else {
                    'Running'
                }
                [PSCustomObject]@{ State = $state }
            }
            Mock Get-VMNetworkAdapter {
                @([PSCustomObject]@{
                    SwitchName  = 'ExternalSwitch-Shared'
                    IPAddresses = @('192.168.42.99')
                })
            }
            Mock Test-VmSshPort { $true }

            $vm = New-DhcpRouterTestVm
            Invoke-VmCreation -Vm $vm -SwitchName 'External'

            # Workload code path reads $vm._RouterVm.ipAddress, which
            # is the same object. Adding the field via Add-Member is
            # what makes the discovery observable to downstream code.
            $vm.PSObject.Properties['ipAddress']        | Should -Not -BeNullOrEmpty
            $vm.ipAddress                                | Should -Be '192.168.42.99'
        }

        It 'throws with a router-specific message when KVP never reports an IP' {
            # The Set-ExpiredDeadline mock keeps the discovery loop from
            # actually running; the IP-discovery branch hits its own
            # "did not report ... within N minutes" throw. The error
            # text differs from the regular SSH-not-reachable throw so
            # the operator can tell which budget ran out.
            Initialize-HyperVMocks
            Set-ExpiredDeadline
            # Default Get-VMNetworkAdapter returns an empty array.

            { Invoke-VmCreation -Vm (New-DhcpRouterTestVm) -SwitchName 'External' } |
                Should -Throw -ExpectedMessage "*did not report an ext0 IP*"
        }

        It 'skips the discovery branch when the router VM has a static ipAddress' {
            # New-RouterTestVm carries ipAddress = '192.168.1.10', so
            # the discovery branch is bypassed. The SSH probe targets
            # the static IP directly. Set-ExpiredDeadline keeps the
            # loop from running.
            Initialize-HyperVMocks
            Set-ExpiredDeadline

            { Invoke-VmCreation -Vm (New-RouterTestVm) -SwitchName 'External' } |
                Should -Throw -ExpectedMessage "*did not become reachable*"

            Should -Invoke Get-VMNetworkAdapter -Times 0 -Exactly
        }
    }

    # ------------------------------------------------------------------
    Context 'SSH polling - jump-host dispatch' {
    # ------------------------------------------------------------------
        # Feature 53 step 3 follow-up: workloads sit on a private switch
        # the host has no route to. Invoke-VmCreation must open an SSH
        # tunnel through the router (stamped onto each workload as
        # _RouterVm by provision.ps1 step 7) and probe localhost on the
        # tunnel's forwarded port instead of the workload IP directly.

        It 'opens New-VmSshTunnel against the router for a workload with _RouterVm' {
            # The polling loop body is skipped by Set-ExpiredDeadline
            # (the deadline is already past on the first iteration),
            # so Test-VmSshPort itself is unobservable here. The
            # localhost-vs-workload-IP probe target is covered by the
            # next test, which inspects the live $probeIp variable
            # via a stop-the-loop assertion.
            Initialize-HyperVMocks
            Set-ExpiredDeadline

            $workload = New-TestVm
            Add-Member -InputObject $workload `
                       -MemberType NoteProperty -Name '_RouterVm' `
                       -Value ([PSCustomObject]@{
                           ipAddress = '192.168.1.20'
                           username  = 'routeradmin'
                           password  = 'router-secret'
                       })

            { Invoke-VmCreation -Vm $workload -SwitchName 'PrivateSwitch-E2E' } |
                Should -Throw    # timeout throw - expected

            Should -Invoke New-VmSshTunnel -Times 1 -Exactly -ParameterFilter {
                $TargetIp     -eq $workload.ipAddress -and
                $JumpHostIp   -eq '192.168.1.20'      -and
                $JumpUsername -eq 'routeradmin'       -and
                $JumpPassword -eq 'router-secret'
            }
        }

        It 'probes the tunnel''s localhost endpoint (not the workload IP)' {
            # Override Test-VmSshPort to record AND return $true so the
            # polling loop exits via the success path on its first
            # iteration. That gives us one observable call to assert
            # against. Without this, Set-ExpiredDeadline's past-
            # deadline mock skips the loop body and the probe target
            # is unobservable.
            Initialize-HyperVMocks
            # Stateful Get-VM: the post-creation guard requires Off
            # (first call) and the polling loop requires Running
            # (subsequent calls). Returning the same state on every
            # call would fail one branch or the other.
            $script:_getVmCallCount = 0
            Mock Get-VM {
                $script:_getVmCallCount++
                $state = if ($script:_getVmCallCount -eq 1) {
                    'Off'
                } else {
                    'Running'
                }
                [PSCustomObject]@{ State = $state }
            }
            $script:_probedIp   = $null
            $script:_probedPort = $null
            Mock Test-VmSshPort {
                param($IpAddress, $Port)
                $script:_probedIp   = $IpAddress
                $script:_probedPort = $Port
                $true
            }

            $workload = New-TestVm
            Add-Member -InputObject $workload `
                       -MemberType NoteProperty -Name '_RouterVm' `
                       -Value ([PSCustomObject]@{
                           ipAddress = '192.168.1.20'
                           username  = 'routeradmin'
                           password  = 'router-secret'
                       })

            Invoke-VmCreation -Vm $workload -SwitchName 'PrivateSwitch-E2E'

            $script:_probedIp   | Should -Be '127.0.0.1'
            $script:_probedPort | Should -Be 12345
        }

        It 'does not open a tunnel for a router VM (no _RouterVm)' {
            # Router VMs are reachable directly on the host's External
            # vSwitch upstream LAN. A tunnel-open here would be a
            # chicken-and-egg.
            Initialize-HyperVMocks
            Set-ExpiredDeadline

            { Invoke-VmCreation -Vm (New-RouterTestVm) -SwitchName 'External' } |
                Should -Throw

            Should -Invoke New-VmSshTunnel -Times 0 -Exactly
        }

        It 'keeps polling when TCP probe succeeds but the SSH banner does not arrive' {
            # SSH.NET ForwardedPortLocal's TCP listener accepts the
            # moment Start() returns, so Test-VmSshPort against the
            # tunnel succeeds INSTANTLY against a workload whose own
            # sshd is not yet serving. Without the banner-read gate,
            # Invoke-VmPostProvisioning then runs a real SSH Connect()
            # that dies with "no SSH identification string". Verify
            # the loop polls until the banner read succeeds, not just
            # until TCP accepts.
            $script:_getVmCallCount = 0
            Initialize-HyperVMocks
            Mock Get-VM {
                $script:_getVmCallCount++
                $state = if ($script:_getVmCallCount -eq 1) {
                    'Off'
                } else {
                    'Running'
                }
                [PSCustomObject]@{ State = $state }
            }
            Mock Test-VmSshPort { $true }
            $script:_bannerCalls = 0
            Mock Test-SshBanner {
                $script:_bannerCalls++
                # First two iterations: banner not present (workload
                # still booting); third iteration: ready.
                $script:_bannerCalls -ge 3
            }

            $workload = New-TestVm
            Add-Member -InputObject $workload `
                       -MemberType NoteProperty -Name '_RouterVm' `
                       -Value ([PSCustomObject]@{
                           ipAddress = '192.168.1.20'
                           username  = 'routeradmin'
                           password  = 'router-secret'
                       })

            Invoke-VmCreation -Vm $workload -SwitchName 'PrivateSwitch-E2E'

            $script:_bannerCalls | Should -Be 3
            Should -Invoke Test-VmSshPort -Times 3 -Exactly
        }

        It 'disposes the tunnel in the finally block when the poll times out' {
            # Per-test isolation: the dispose counter lives on a script
            # scope that persists across calls; reset it before this
            # specific It so a prior It does not bleed into the count.
            $script:_tunnelDisposed = 0
            Initialize-HyperVMocks
            Set-ExpiredDeadline

            $workload = New-TestVm
            Add-Member -InputObject $workload `
                       -MemberType NoteProperty -Name '_RouterVm' `
                       -Value ([PSCustomObject]@{
                           ipAddress = '192.168.1.20'
                           username  = 'routeradmin'
                           password  = 'router-secret'
                       })

            { Invoke-VmCreation -Vm $workload -SwitchName 'PrivateSwitch-E2E' } |
                Should -Throw

            $script:_tunnelDisposed | Should -Be 1
        }
    }

    # ------------------------------------------------------------------
    Context 'finally block - seed ISO cleanup' {
    # ------------------------------------------------------------------
        # The seed ISO is always removed regardless of whether SSH succeeds
        # or times out. It contains the plaintext password and must never
        # persist on the host disk after provisioning.

        It 'detaches the DVD drive in the finally block on timeout' {
            Initialize-HyperVMocks
            Set-ExpiredDeadline

            { Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN' } |
                Should -Throw

            Should -Invoke Remove-VMDvdDrive -Times 1 -Exactly -ParameterFilter {
                $VMName             -eq 'node-01' -and
                $ControllerNumber   -eq 1          -and
                $ControllerLocation -eq 0
            }
        }

        It 'deletes the seed ISO file in the finally block on timeout' {
            Initialize-HyperVMocks
            Set-ExpiredDeadline
            Mock Test-Path  { $true }    # ISO present on disk
            Mock Remove-Item { }

            { Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN' } |
                Should -Throw

            Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter {
                $Path  -eq 'C:\VMs\node-01\node-01-seed.iso' -and
                $Force -eq $true
            }
        }

        It 'does not call Remove-Item when the seed ISO file is already gone' {
            Initialize-HyperVMocks
            Set-ExpiredDeadline
            Mock Test-Path   { $false }    # ISO already deleted
            Mock Remove-Item { }

            { Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN' } |
                Should -Throw

            Should -Invoke Remove-Item -Times 0
        }

        It 'skips Remove-VMDvdDrive when no matching DVD drive is found' {
            # If Add-VMDvdDrive failed before throwing, Get-VMDvdDrive returns
            # nothing. The finally block must handle a $null drive gracefully.
            Initialize-HyperVMocks
            Set-ExpiredDeadline
            Mock Get-VMDvdDrive    { }    # no drives attached
            Mock Remove-VMDvdDrive { }

            { Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN' } |
                Should -Throw

            Should -Invoke Remove-VMDvdDrive -Times 0
        }
    }
}
