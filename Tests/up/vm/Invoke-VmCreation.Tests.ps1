# PSAvoidOverwritingBuiltInCmdlets is suppressed file-wide: the BeforeAll
# stubs deliberately shadow built-in cmdlets so Pester has a symbol to
# mock and no call reaches the real host. This is the test-double seam,
# not accidental shadowing.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidOverwritingBuiltInCmdlets', '',
    Justification = 'Test stubs deliberately shadow built-ins as a Pester mock seam')]
param()

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

    # Stub the per-VM diag-folder retention sweep. The real helper
    # ships in Common.PowerShell (Limit-RetainedItem) which
    # provision.ps1's bootstrap imports before create-vm.ps1 runs.
    # Creation tests exercise Hyper-V dispatch + diag-timestamp
    # seeding, not file pruning, so a no-op stub keeps the focus.
    function Limit-RetainedItem {
        param($Directory, $Filter, $MaxItems, $MaxAgeDays, [switch] $FileOnly)
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
    # Assert-WorkloadReachableViaRouter is the router-side reachability
    # gate that runs the nc-banner-read probe + diag bundle capture.
    # Stub it here so Invoke-VmCreation tests do not have to know
    # about its internals (the helper has its own focused test file).
    # Default is a no-op success; tests that need the failure branch
    # override with `Mock ... { throw ... }`.
    function Assert-WorkloadReachableViaRouter {
        param(
            $JumpClient, $WorkloadIp, $WorkloadVmName, $RouterVmName,
            $DiagFolder, $TimeoutSeconds, $PollIntervalSeconds, $OnPoll
        )
    }
    function New-VmSshTunnel {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSAvoidUsingPlainTextForPassword', 'JumpPassword')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSAvoidUsingUsernameAndPasswordParams', '')]
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

    # KVP IP-discovery helper now lives in Infrastructure.HyperV >= 0.11.0
    # (extracted from create-vm.ps1's inline loop). The provisioner tests
    # do not exercise the helper's polling internals - those have their
    # own coverage in Infrastructure-HyperV/Tests/Get-VmKvpIpAddress.Tests.ps1.
    # The stub returns a sentinel IP; per-test mocks override when a
    # specific discovered address matters (e.g. the "writes the
    # discovered IP back onto the VM def" test).
    function Get-VmKvpIpAddress {
        param(
            [string]      $VmName,
            [string]      $SwitchName,
            [int]         $TimeoutMinutes,
            [int]         $PollIntervalSeconds,
            [scriptblock] $OnPoll
        )
        '192.168.1.42'
    }

    # Wait-VmSshBannerReachable extracted from create-vm.ps1's inline
    # polling loop. Its internals (TCP probe + banner gate + OnPoll
    # ordering + dot painting) have their own coverage in
    # Tests\common\ssh\Wait-VmSshBannerReachable.Tests.ps1; the stub
    # here defaults to "ready immediately" so happy-path tests reach
    # the post-wait cleanup. Tests that exercise the timeout branch
    # override with `Mock Wait-VmSshBannerReachable { $false }`.
    function Wait-VmSshBannerReachable {
        param(
            [string]      $IpAddress,
            [int]         $Port,
            [datetime]    $Deadline,
            [int]         $PollIntervalSeconds = 10,
            [scriptblock] $OnPoll
        )
        # Honour Set-ExpiredDeadline (and any other test that mocks
        # Get-Date to return a far-future timestamp) by reporting
        # timeout when the deadline is already in the past. Order
        # matters: the real Wait-VmSshBannerReachable's `while ((Get-
        # Date) -lt $Deadline)` checks the deadline BEFORE the body,
        # so OnPoll never fires on an already-past deadline. Real-time
        # tests have $Deadline well in the future, so the default
        # path falls through to the OnPoll fire + success return.
        if ((Get-Date) -ge $Deadline) { return $false }
        # Forward the OnPoll fire so callers' VM-state guards still
        # trigger - the "VM stopped unexpectedly" tests rely on that
        # pathway throwing through the stub.
        if ($null -ne $OnPoll) { & $OnPoll }
        $true
    }

    # Format-ElapsedBudgetWithGradient owns the ANSI elapsed-time tail.
    # Its internals (colour math + clamp) live in Tests\common\ui\
    # Format-ElapsedBudgetWithGradient.Tests.ps1. The stub here
    # returns an inert string so Write-Host has something to print
    # without coupling create-vm tests to the colour-code layout.
    function Format-ElapsedBudgetWithGradient {
        param([int] $ElapsedSeconds, [int] $BudgetSeconds, [bool] $Succeeded)
        "${ElapsedSeconds}s / ${BudgetSeconds}s"
    }

    # Remove-VmSeedIso owns the Get-VMDvdDrive -> Remove-VMDvdDrive ->
    # Remove-Item sequence. Tests\up\vm\Remove-VmSeedIso.Tests.ps1
    # covers it directly; this stub records the call so the create-vm
    # finally-block dispatch tests can assert seed-ISO cleanup
    # happened without inspecting the underlying cmdlets.
    function Remove-VmSeedIso {
        param([string] $VmName, [string] $SeedIsoPath)
    }

    # Pure path helper - dot-source the real implementation so the
    # diag-folder shape under test matches production exactly.
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\common\diag\Get-VmDiagFolder.ps1"
    # Invoke-VmRuntimeDiag fires from create-vm.ps1's timeout-path
    # catches; stub at file scope so the diag-fire is a no-op in
    # tests that exercise those paths.
    function Invoke-VmRuntimeDiag {
        param($Vm, $VmConfigPath, $Timestamp, $SshOpenTimeout)
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
                LocalHost  = '127.0.0.1'
                LocalPort  = 12345
                # Sentinel JumpClient - real tests assert via Should-Invoke
                # on Invoke-SshClientCommand rather than inspecting this.
                JumpClient = [PSCustomObject]@{ _stub = 'jump-client' }
            }
            Add-Member -InputObject $obj -MemberType ScriptMethod `
                       -Name Dispose -Value {
                $script:_tunnelDisposed++
            }
            $obj
        }
        # Router-side reachability gate. Default is a silent success
        # so the canonical happy-path tests reach the host-side poll
        # without each having to know about this gate. Tests that
        # exercise the failure-mode wiring override with a throw.
        Mock Assert-WorkloadReachableViaRouter { }

        # Pester requires the function to be Mock'd (not just defined
        # at file scope) for Should -Invoke to work. Register default
        # mocks for each extracted helper.
        #
        # Wait-VmSshBannerReachable's default Mock does NOT fire
        # OnPoll: closures executed from inside a Pester Mock body
        # resolve commands via the original file-scope stub rather
        # than the test's per-It Mocks (Get-VM in particular), which
        # makes stateful Get-VM counter tests silently see empty
        # state. Tests that specifically exercise OnPoll behaviour
        # override this Mock locally to fire the callback.
        Mock Remove-VmSeedIso { }
        Mock Wait-VmSshBannerReachable {
            param([string] $IpAddress, [int] $Port, [datetime] $Deadline,
                  [int] $PollIntervalSeconds, [scriptblock] $OnPoll)
            if ((Get-Date) -ge $Deadline) { return $false }
            $true
        }
        Mock Format-ElapsedBudgetWithGradient { 'stub-elapsed-output' }
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

        It 'passes a non-null OnPoll callback to Wait-VmSshBannerReachable' {
            # The polling loop's per-iteration "VM still Running?"
            # check is Hyper-V-specific and lives in the OnPoll
            # callback create-vm.ps1 hands to the helper. Verify the
            # callback is non-null via Pester's parameter filter -
            # DO NOT actually fire it from inside a Pester Mock body.
            # The OnPoll closure resolves Get-VM via the calling
            # session state, NOT the test's per-It Mock layer, so a
            # fired closure inside a Mock body silently calls the
            # real Hyper-V Get-VM cmdlet - which emits "permission
            # denied" to stderr on any non-admin runner (CI, dev
            # boxes without Hyper-V Administrators membership) even
            # though the test itself passes.
            #
            # The callback's BEHAVIOUR (firing Get-VM and throwing on
            # non-Running state) is covered by
            # Tests\common\ssh\Wait-VmSshBannerReachable.Tests.ps1's
            # "propagates an OnPoll throw" test running against the
            # real helper, not a Pester Mock - the closure-vs-Mock
            # interaction does not bite there.
            Initialize-HyperVMocks

            Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN'

            Should -Invoke Wait-VmSshBannerReachable -Times 1 -Exactly `
                -ParameterFilter {
                    $null -ne $OnPoll -and $OnPoll -is [scriptblock]
                }
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

        It 'delegates to Get-VmKvpIpAddress with the external switch name' {
            # KVP polling logic lives in Infrastructure.HyperV's
            # Get-VmKvpIpAddress (its own test suite covers the
            # state guard, IPv4 filter, deadline behaviour). What
            # the provisioner must still own is the call - pass the
            # router's vmName and externalSwitchName so the helper
            # picks the right NIC on multi-adapter VMs.
            Initialize-HyperVMocks
            # Stateful Get-VM: Off for the post-creation guard, then
            # Running for the SSH probe loop. Mirrors the pattern in
            # the jump-host dispatch tests.
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
            Mock Get-VmKvpIpAddress { '192.168.1.42' }
            # Capture the IP Wait-VmSshBannerReachable is asked to
            # probe so we can verify the discovered KVP address flows
            # through. The original test inspected Test-VmSshPort
            # directly; with Wait-VmSshBannerReachable extracted, that
            # is now a parameter on the helper.
            $script:_probedIpAfterDiscovery = $null
            Mock Wait-VmSshBannerReachable {
                param([string] $IpAddress, [int] $Port, [datetime] $Deadline,
                      [int] $PollIntervalSeconds, [scriptblock] $OnPoll)
                $script:_probedIpAfterDiscovery = $IpAddress
                $true
            }

            Invoke-VmCreation -Vm (New-DhcpRouterTestVm) -SwitchName 'External'

            Should -Invoke Get-VmKvpIpAddress -ParameterFilter {
                $VmName -eq 'router-01' -and
                $SwitchName -eq 'ExternalSwitch-Shared'
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
            Mock Get-VmKvpIpAddress { '192.168.42.99' }
            Mock Test-VmSshPort     { $true }

            $vm = New-DhcpRouterTestVm
            Invoke-VmCreation -Vm $vm -SwitchName 'External'

            # Workload code path reads $vm._RouterVm.ipAddress, which
            # is the same object. Adding the field via Add-Member is
            # what makes the discovery observable to downstream code.
            $vm.PSObject.Properties['ipAddress']        | Should -Not -BeNullOrEmpty
            $vm.ipAddress                                | Should -Be '192.168.42.99'
        }

        It 'propagates the Get-VmKvpIpAddress throw on discovery timeout' {
            # The module helper owns the "did not report ... within N
            # minutes" wording; the provisioner just lets it propagate.
            # A bare 'throw' inside the Mock keeps the message intact
            # rather than re-wrapping.
            Initialize-HyperVMocks
            Mock Get-VmKvpIpAddress {
                throw "VM 'router-01' did not report an IPv4 address via Hyper-V KVP within 10 minute(s)."
            }

            { Invoke-VmCreation -Vm (New-DhcpRouterTestVm) -SwitchName 'External' } |
                Should -Throw -ExpectedMessage "*did not report an IPv4 address*"
        }

        It 'skips the discovery branch when the router VM has a static ipAddress' {
            # New-RouterTestVm carries ipAddress = '192.168.1.10', so
            # the discovery branch is bypassed. The SSH probe targets
            # the static IP directly. Set-ExpiredDeadline keeps the
            # loop from running. Mock Get-VmKvpIpAddress registers the
            # function with Pester (required for Should -Invoke even
            # at -Times 0) so a regression that re-introduces a call
            # is caught here.
            Initialize-HyperVMocks
            Set-ExpiredDeadline
            Mock Get-VmKvpIpAddress { '192.168.0.0' }

            { Invoke-VmCreation -Vm (New-RouterTestVm) -SwitchName 'External' } |
                Should -Throw -ExpectedMessage "*did not become reachable*"

            Should -Invoke Get-VmKvpIpAddress -Times 0 -Exactly
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
                           vmName    = 'router-prod'
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

        It 'asks Wait-VmSshBannerReachable to probe the tunnel''s localhost endpoint (not the workload IP)' {
            # The wait-for-SSH polling loop body now lives in Wait-
            # VmSshBannerReachable; its own tests cover the TCP-then-
            # banner gating. What Invoke-VmCreation still owns is the
            # endpoint choice: the tunnel's loopback host + port, not
            # the workload's private-switch IP.
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

            $workload = New-TestVm
            Add-Member -InputObject $workload `
                       -MemberType NoteProperty -Name '_RouterVm' `
                       -Value ([PSCustomObject]@{
                           vmName    = 'router-prod'
                           ipAddress = '192.168.1.20'
                           username  = 'routeradmin'
                           password  = 'router-secret'
                       })

            Invoke-VmCreation -Vm $workload -SwitchName 'PrivateSwitch-E2E'

            Should -Invoke Wait-VmSshBannerReachable -Times 1 -Exactly `
                -ParameterFilter {
                    $IpAddress -eq '127.0.0.1' -and $Port -eq 12345
                }
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

        It 'delegates to Assert-WorkloadReachableViaRouter with the tunnel''s JumpClient and the workload IP' {
            # The gate's internals (probe shape, diag capture, hints)
            # have their own tests in Tests\common\network\Assert-
            # WorkloadReachableViaRouter.Tests.ps1. Here we assert the
            # wiring from Invoke-VmCreation: the workload IP, vmName,
            # router vmName, and the JumpClient we got back from
            # New-VmSshTunnel all flow into the helper.
            $script:_getVmCallCount = 0
            Initialize-HyperVMocks
            Mock Get-VM {
                $script:_getVmCallCount++
                $state = if ($script:_getVmCallCount -eq 1) { 'Off' } else { 'Running' }
                [PSCustomObject]@{ State = $state }
            }
            Mock Test-VmSshPort { $true }

            $workload = New-TestVm
            Add-Member -InputObject $workload `
                       -MemberType NoteProperty -Name '_RouterVm' `
                       -Value ([PSCustomObject]@{
                           vmName    = 'router-prod'
                           ipAddress = '192.168.1.20'
                           username  = 'routeradmin'
                           password  = 'router-secret'
                       })

            Invoke-VmCreation -Vm $workload -SwitchName 'PrivateSwitch-E2E'

            Should -Invoke Assert-WorkloadReachableViaRouter -Times 1 -Exactly `
                -ParameterFilter {
                    $WorkloadIp     -eq '192.168.1.10' -and
                    $WorkloadVmName -eq 'node-01'     -and
                    $RouterVmName   -eq 'router-prod' -and
                    $JumpClient._stub -eq 'jump-client'
                }
        }

        It 'fails fast with the helper''s throw when it rejects reachability' {
            # The gate's own tests cover the message-shaping and diag-
            # capture branches. Here we just confirm the orchestrator
            # surfaces a helper throw to the caller as-is, instead of
            # swallowing it and falling through to the host-side poll.
            $script:_getVmCallCount = 0
            Initialize-HyperVMocks
            Mock Get-VM {
                $script:_getVmCallCount++
                $state = if ($script:_getVmCallCount -eq 1) { 'Off' } else { 'Running' }
                [PSCustomObject]@{ State = $state }
            }
            Mock Assert-WorkloadReachableViaRouter {
                throw "Router 'router-prod' cannot reach workload 'node-01' at 192.168.1.10:22 within 300 seconds."
            }

            $workload = New-TestVm
            Add-Member -InputObject $workload `
                       -MemberType NoteProperty -Name '_RouterVm' `
                       -Value ([PSCustomObject]@{
                           vmName    = 'router-prod'
                           ipAddress = '192.168.1.20'
                           username  = 'routeradmin'
                           password  = 'router-secret'
                       })

            { Invoke-VmCreation -Vm $workload -SwitchName 'PrivateSwitch-E2E' } |
                Should -Throw -ExpectedMessage "*Router 'router-prod' cannot reach workload*"
        }

        It 'does NOT run the router-side gate for direct (no _RouterVm) targets' {
            # Router VMs and any pre-feature-53 caller take the no-tunnel
            # branch above; the gate is tunnel-specific and must not fire
            # for them.
            Initialize-HyperVMocks
            Set-ExpiredDeadline

            { Invoke-VmCreation -Vm (New-RouterTestVm) -SwitchName 'External' } |
                Should -Throw

            Should -Invoke Assert-WorkloadReachableViaRouter -Times 0 -Exactly
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
                           vmName    = 'router-prod'
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
        # The seed ISO contains the plaintext password and must never
        # persist on the host disk after provisioning. Removal lives in
        # Remove-VmSeedIso (its own test file covers the detach + delete
        # ordering and the idempotent skip branches); here we just
        # verify the cleanup is dispatched from create-vm.ps1's finally
        # regardless of whether wait-for-SSH succeeded or timed out.

        It 'invokes Remove-VmSeedIso in the finally block on timeout' {
            Initialize-HyperVMocks
            Set-ExpiredDeadline

            { Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN' } |
                Should -Throw

            Should -Invoke Remove-VmSeedIso -Times 1 -Exactly -ParameterFilter {
                $VmName      -eq 'node-01' -and
                $SeedIsoPath -eq 'C:\VMs\node-01\node-01-seed.iso'
            }
        }

        It 'invokes Remove-VmSeedIso in the finally block on success' {
            # Mirror test for the happy path - the cleanup must NOT be
            # conditional on the SSH probe outcome.
            Initialize-HyperVMocks
            # Stateful Get-VM: Off (post-creation guard) then Running
            # (so the wait-for-SSH stub's OnPoll forward does not throw).
            $script:_getVmCallCount = 0
            Mock Get-VM {
                $script:_getVmCallCount++
                $state = if ($script:_getVmCallCount -eq 1) { 'Off' } else { 'Running' }
                [PSCustomObject]@{ State = $state }
            }

            Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN'

            Should -Invoke Remove-VmSeedIso -Times 1 -Exactly -ParameterFilter {
                $VmName      -eq 'node-01' -and
                $SeedIsoPath -eq 'C:\VMs\node-01\node-01-seed.iso'
            }
        }
    }
}
