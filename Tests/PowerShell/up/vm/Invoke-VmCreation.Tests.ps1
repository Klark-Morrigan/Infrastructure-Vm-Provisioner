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
    function Set-VM                    { param($Name, $AutomaticStopAction) }
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

    # Wait-VmSshAccessible is the topology-aware reachability helper
    # create-vm.ps1 delegates the whole tunnel/gate/poll block to. Its
    # internals - tunnel open/dispose, the banner poll, the probe-endpoint
    # choice - have their own coverage in
    # Tests\common\ssh\Wait-VmSshAccessible.Tests.ps1. Stub it here so
    # Pester's Mock can attach by name; the default returns a reachable
    # result object so the happy-path tests run to completion. Tests that
    # exercise the timeout branch override with a $false Reachable result,
    # and the gate-wiring tests capture the -OnTunnelOpened / -OnPoll
    # scriptblocks create-vm hands in and fire them directly.
    function Wait-VmSshAccessible {
        param(
            [object]      $Vm,
            [object]      $RouterVm,
            [datetime]    $Deadline,
            [int]         $PollIntervalSeconds = 10,
            [scriptblock] $OnPoll,
            [scriptblock] $OnTunnelOpened
        )
        [PSCustomObject]@{
            Reachable      = $true
            ProbeIp        = '127.0.0.1'
            ProbePort      = 22
            ElapsedSeconds = 0
        }
    }

    # Assert-WorkloadReachableViaRouter is the router-side reachability
    # gate create-vm.ps1 wraps in the -OnTunnelOpened scriptblock it
    # passes to Wait-VmSshAccessible. The helper fires that scriptblock
    # against the live tunnel; here the helper is mocked, so the gate
    # tests capture the scriptblock and fire it directly. Stub as a no-op
    # success; the failure-mode tests override with a throw.
    function Assert-WorkloadReachableViaRouter {
        param(
            $JumpClient, $WorkloadIp, $WorkloadVmName, $RouterVmName,
            $DiagFolder, $TimeoutSeconds, $PollIntervalSeconds, $OnPoll
        )
    }

    # Assert-VmSshCredentialsAccepted is the router-only authenticated
    # gate that runs AFTER a reachable result: it proves the configured
    # account actually logs in (a cloud-init user-creation failure leaves
    # sshd serving a banner with no usable login). Its own behaviour is
    # covered in Tests\common\ssh\Assert-VmSshCredentialsAccepted.Tests.ps1;
    # stub it here as a no-op success so router happy-path tests reach the
    # post-wait cleanup. Tests that need the rejection branch override with
    # `Mock Assert-VmSshCredentialsAccepted { throw ... }`.
    function Assert-VmSshCredentialsAccepted {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSAvoidUsingPlainTextForPassword', 'Password')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSAvoidUsingUsernameAndPasswordParams', '')]
        param(
            [string]   $IpAddress,
            [string]   $Username,
            [string]   $Password,
            [string]   $VmName,
            [int]      $Port = 22,
            [TimeSpan] $Timeout = [TimeSpan]::FromSeconds(30),
            [string]   $ConsoleLogPath
        )
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

    # Diag-folder path helper. Its shape is covered by
    # Tests\common\diag\Get-VmDiagFolder.Tests.ps1; here it is stubbed so
    # Pester's Mock can attach. The Mock matters for the gate-wiring
    # tests: they capture the -OnTunnelOpened closure create-vm builds and
    # fire it at It scope, where only Mock'd commands - not plain
    # dot-sourced functions - resolve from the closure's session state.
    function Get-VmDiagFolder {
        param($VmConfigPath, $VmName, $Timestamp)
        Join-Path (Join-Path (Join-Path $VmConfigPath 'diagnostics') $VmName) $Timestamp
    }
    # Invoke-VmRuntimeDiag fires from create-vm.ps1's timeout-path catch
    # and the -OnTunnelOpened gate's failure catch; stub at file scope so
    # the diag-fire is a no-op in tests that exercise those paths.
    function Invoke-VmRuntimeDiag {
        param($Vm, $VmConfigPath, $Timestamp, $SshOpenTimeout)
    }

    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\up\vm\create-vm.ps1"

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

    # Workload VM with the _RouterVm jump-host stamp provision.ps1 adds at
    # step 7 - the tunnelled-reachability branch (router present).
    function New-WorkloadWithRouter {
        $workload = New-TestVm
        Add-Member -InputObject $workload `
                   -MemberType NoteProperty -Name '_RouterVm' `
                   -Value ([PSCustomObject]@{
                       vmName    = 'router-prod'
                       ipAddress = '192.168.1.20'
                       username  = 'routeradmin'
                       password  = 'router-secret'
                   })
        $workload
    }

    # Router VM object - extra fields exercised by the dual-NIC branch.
    # Pester 5 only hoists function defs from BeforeAll (not Context),
    # so this lives at top-level alongside New-TestVm.
    function New-RouterTestVm {
        [PSCustomObject]@{
            vmName              = 'router-01'
            vmConfigPath        = 'C:\a_VMs\Hyper-V\Config'
            username            = 'admin'
            password            = 'router-secret'
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
            password            = 'router-secret'
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

    # Fake tunnel handed to a captured -OnTunnelOpened scriptblock so the
    # gate-wiring tests can assert the JumpClient flows into
    # Assert-WorkloadReachableViaRouter, mirroring the live tunnel object
    # Wait-VmSshAccessible would pass in production.
    function New-FakeTunnel {
        [PSCustomObject]@{
            LocalHost  = '127.0.0.1'
            LocalPort  = 12345
            JumpClient = [PSCustomObject]@{ _stub = 'jump-client' }
        }
    }

    # Fires create-vm's captured -OnTunnelOpened gate against a fake tunnel.
    # The gate is a plain scriptblock (NOT .GetNewClosure() - see create-vm.ps1
    # for why) that calls its helpers by bare name and reads its VM def from
    # $script:onTunnelGateVm. Built during Invoke-VmCreation in this test
    # session state, it stays bound here, so firing it as-is resolves the bare
    # calls straight to the per-It mocks - no source rebind needed. $Vm was
    # stamped into $script:onTunnelGateVm when the gate was built, so the
    # block already sees the right def.
    function Invoke-CapturedGate {
        param([scriptblock] $Gate, [object] $Tunnel)
        & $Gate $Tunnel
    }

    # Sets up the Hyper-V creation stubs in their neutral no-op form, the
    # reachability helper in its reachable-result form, and the finally-
    # block stubs so cleanup always runs cleanly.
    function Initialize-HyperVMocks {
        Mock New-VM              { }
        Mock Set-VM              { }
        Mock Set-VMProcessor     { }
        Mock Get-VMHardDiskDrive { [PSCustomObject]@{ Path = 'disk.vhdx' } }
        Mock Set-VMFirmware      { }
        Mock Add-VMDvdDrive      { }
        Mock Connect-VMNetworkAdapter { }
        Mock Set-VMNetworkAdapter     { }
        Mock Add-VMNetworkAdapter     { }
        Mock Start-VM            { }
        # Return Off state by default so the post-creation guard passes.
        # The wait-for-SSH loop's Get-VM calls live inside the mocked
        # Wait-VmSshAccessible, so the guard is the only caller here.
        Mock Get-VM              { [PSCustomObject]@{ State = 'Off' } }
        # IP discovery (KVP) defaults to "no adapters found"; workload +
        # router-static fixtures carry ipAddress and never hit it.
        Mock Get-VMNetworkAdapter { @() }

        # Reachability helper: reachable by default so happy-path tests
        # reach the post-wait credential gate + cleanup. Returns the
        # result-object shape create-vm reads $result.Reachable off.
        Mock Wait-VmSshAccessible {
            [PSCustomObject]@{
                Reachable      = $true
                ProbeIp        = '127.0.0.1'
                ProbePort      = 22
                ElapsedSeconds = 1
            }
        }
        # Router-side reachability gate, fired by create-vm's
        # -OnTunnelOpened scriptblock. Default silent success; the
        # failure-wiring test overrides with a throw.
        Mock Assert-WorkloadReachableViaRouter { }
        # Router-only authenticated credential gate (runs after a
        # reachable result). Default success so router happy-path tests
        # reach cleanup; the wiring tests assert it fired for routers /
        # not for workloads.
        Mock Assert-VmSshCredentialsAccepted { }
        # Diag-folder path helper. Mock'd (not just stubbed) so the
        # captured -OnTunnelOpened closure resolves it when a gate-wiring
        # test fires it at It scope - see the function's BeforeAll note.
        Mock Get-VmDiagFolder { 'C:\a_VMs\Hyper-V\Config\diagnostics\node-01\ts' }
        # Diag fired from the timeout path and the gate-failure catch.
        Mock Invoke-VmRuntimeDiag { }
        # Finally-block cleanup. Mock'd (not just stubbed) so the
        # finally-dispatch tests can assert both fired regardless of the
        # reachable/timeout outcome.
        Mock Stop-SerialConsoleCapture { }
        Mock Remove-VmSeedIso { }
        Mock Format-ElapsedBudgetWithGradient { 'stub-elapsed-output' }
    }
}

Describe 'Invoke-VmCreation' {

    # ------------------------------------------------------------------
    Context 'VM creation parameters' {
    # ------------------------------------------------------------------

        It 'creates a Gen 2 VM with the correct name, RAM, VHDX, and config path' {
            Initialize-HyperVMocks

            Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN'

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

            Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN'

            Should -Invoke Set-VMProcessor -Times 1 -Exactly -ParameterFilter {
                $VMName -eq 'node-01' -and $Count -eq 2
            }
        }

        It 'sets AutomaticStopAction to ShutDown so host stop is a clean cold boot' {
            # Overrides the Hyper-V default (Save), which would resume the
            # runner systemd unit mid-flight against a dead GitHub
            # connection. A cold boot re-runs the enabled unit so the
            # runner reconnects on its own after a host reboot.
            Initialize-HyperVMocks

            Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN'

            Should -Invoke Set-VM -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'node-01' -and $AutomaticStopAction -eq 'ShutDown'
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

            Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN'

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

            Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN'

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

            Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'PrivateSwitch-Production'

            Should -Invoke Connect-VMNetworkAdapter -Times 1 -Exactly -ParameterFilter {
                $VMName     -eq 'node-01' -and
                $SwitchName -eq 'PrivateSwitch-Production'
            }
        }

        It 'does not pin a static MAC for a workload VM' {
            # Workload VMs let Hyper-V auto-assign MACs; the static-MAC
            # path is router-specific.
            Initialize-HyperVMocks

            Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'PrivateSwitch-Production'

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

            Invoke-VmCreation -Vm (New-RouterTestVm) -SwitchName 'ExternalSwitch-Shared'

            Should -Invoke Connect-VMNetworkAdapter -Times 1 -Exactly -ParameterFilter {
                $VMName     -eq 'router-01' -and
                $SwitchName -eq 'ExternalSwitch-Shared'
            }
        }

        It 'pins the external NIC MAC via Set-VMNetworkAdapter' {
            Initialize-HyperVMocks

            Invoke-VmCreation -Vm (New-RouterTestVm) -SwitchName 'ExternalSwitch-Shared'

            Should -Invoke Set-VMNetworkAdapter -Times 1 -Exactly -ParameterFilter {
                $VMName           -eq 'router-01' -and
                $Name             -eq 'Network Adapter' -and
                $StaticMacAddress -eq '02aabbccdd00'
            }
        }

        It 'adds a second NIC named Private on privateSwitchName with the private MAC' {
            Initialize-HyperVMocks

            Invoke-VmCreation -Vm (New-RouterTestVm) -SwitchName 'ExternalSwitch-Shared'

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

            Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN'

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
    Context 'reachability delegation (Wait-VmSshAccessible)' {
    # ------------------------------------------------------------------
        # Feature 67 step 4: create-vm.ps1 collapsed its inline tunnel +
        # router-side gate + banner poll into a single Wait-VmSshAccessible
        # call. These tests pin the wiring create-vm still owns: which VM
        # kind gets a router def + tunnel-time gate, the per-poll guard,
        # and the deadline/interval forwarding. The helper's own behaviour
        # (probe-endpoint choice, tunnel lifecycle, banner poll) is covered
        # by Tests\common\ssh\Wait-VmSshAccessible.Tests.ps1.

        It 'invokes the helper once with the router def and an -OnTunnelOpened gate for a workload' {
            Initialize-HyperVMocks

            Invoke-VmCreation -Vm (New-WorkloadWithRouter) -SwitchName 'PrivateSwitch-E2E'

            Should -Invoke Wait-VmSshAccessible -Times 1 -Exactly -ParameterFilter {
                $null -ne $RouterVm                  -and
                $RouterVm.vmName -eq 'router-prod'   -and
                $null -ne $OnTunnelOpened            -and
                $null -ne $OnPoll
            }
        }

        It 'invokes the helper with a null router and no -OnTunnelOpened for a router VM' {
            # A router is reachable directly on the host's upstream LAN -
            # no jump host, so no tunnel-time gate. The per-poll VM-state
            # guard still flows through.
            Initialize-HyperVMocks

            Invoke-VmCreation -Vm (New-RouterTestVm) -SwitchName 'ExternalSwitch-Shared'

            Should -Invoke Wait-VmSshAccessible -Times 1 -Exactly -ParameterFilter {
                $null -eq $RouterVm       -and
                $null -eq $OnTunnelOpened -and
                $null -ne $OnPoll
            }
        }

        It 'forwards the 10s poll interval and a datetime deadline to the helper' {
            Initialize-HyperVMocks

            Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN'

            Should -Invoke Wait-VmSshAccessible -Times 1 -Exactly -ParameterFilter {
                $PollIntervalSeconds -eq 10 -and $Deadline -is [datetime]
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'router-side gate wiring (-OnTunnelOpened)' {
    # ------------------------------------------------------------------
        # The router-side reachability gate lives in the -OnTunnelOpened
        # scriptblock create-vm hands to the helper. In production the
        # helper fires it against the live tunnel; here the helper is
        # mocked, so these tests capture the scriptblock and fire it
        # directly with a fake tunnel to prove the wiring is intact.

        It 'builds an -OnTunnelOpened gate that probes via the tunnel JumpClient' {
            Initialize-HyperVMocks
            $script:capturedGate = $null
            Mock Wait-VmSshAccessible {
                $script:capturedGate = $OnTunnelOpened
                [PSCustomObject]@{ Reachable = $true; ProbeIp = '127.0.0.1'; ProbePort = 12345; ElapsedSeconds = 1 }
            }

            $workload = New-WorkloadWithRouter
            Invoke-VmCreation -Vm $workload -SwitchName 'PrivateSwitch-E2E'

            $script:capturedGate | Should -Not -BeNullOrEmpty
            Invoke-CapturedGate -Gate $script:capturedGate -Tunnel (New-FakeTunnel)

            Should -Invoke Assert-WorkloadReachableViaRouter -Times 1 -Exactly -ParameterFilter {
                $JumpClient._stub -eq 'jump-client' -and
                $WorkloadIp       -eq '192.168.1.10' -and
                $WorkloadVmName   -eq 'node-01' -and
                $RouterVmName     -eq 'router-prod'
            }
        }

        It 'fires the runtime diag and rethrows when the router-side probe rejects reachability' {
            # Behaviour preserved from the old inline gate's catch: end the
            # dot line, surface the error, capture host+guest runtime diag,
            # then rethrow so create-vm's finally still cleans up.
            Initialize-HyperVMocks
            $script:capturedGate = $null
            Mock Wait-VmSshAccessible {
                $script:capturedGate = $OnTunnelOpened
                [PSCustomObject]@{ Reachable = $true; ProbeIp = '127.0.0.1'; ProbePort = 12345; ElapsedSeconds = 1 }
            }
            Mock Assert-WorkloadReachableViaRouter {
                throw "Router 'router-prod' cannot reach workload 'node-01' at 192.168.1.10:22."
            }

            $workload = New-WorkloadWithRouter
            Invoke-VmCreation -Vm $workload -SwitchName 'PrivateSwitch-E2E'

            { Invoke-CapturedGate -Gate $script:capturedGate -Tunnel (New-FakeTunnel) } |
                Should -Throw -ExpectedMessage "*Router 'router-prod' cannot reach workload*"
            Should -Invoke Invoke-VmRuntimeDiag -Times 1 -Exactly
        }
    }

    # ------------------------------------------------------------------
    Context 'reachability outcome handling' {
    # ------------------------------------------------------------------

        It 'throws the timeout headline and fires runtime diag when the helper reports unreachable' {
            Initialize-HyperVMocks
            Mock Wait-VmSshAccessible {
                [PSCustomObject]@{ Reachable = $false; ProbeIp = '192.168.1.10'; ProbePort = 22; ElapsedSeconds = 600 }
            }

            { Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN' } |
                Should -Throw -ExpectedMessage '*did not become reachable*'

            Should -Invoke Invoke-VmRuntimeDiag -Times 1 -Exactly
        }

        It 'runs the authenticated credential gate for a router once it is reachable' {
            # Banner-reachable proves only that sshd answers; a router is
            # the jump host every workload authenticates through, so its
            # configured login is verified (against its own IP) before it
            # is declared ready.
            Initialize-HyperVMocks

            Invoke-VmCreation -Vm (New-RouterTestVm) -SwitchName 'ExternalSwitch-Shared'

            Should -Invoke Assert-VmSshCredentialsAccepted -Times 1 -Exactly -ParameterFilter {
                $IpAddress -eq '192.168.1.10' -and
                $Username  -eq 'admin'        -and
                $VmName    -eq 'router-01'
            }
        }

        It 'does NOT run the credential gate for a workload VM' {
            # Workloads authenticate via their own post-provisioning
            # session, which surfaces the same fault directly; the
            # router-only gate must not fire for them.
            Initialize-HyperVMocks

            Invoke-VmCreation -Vm (New-WorkloadWithRouter) -SwitchName 'PrivateSwitch-E2E'

            Should -Invoke Assert-VmSshCredentialsAccepted -Times 0 -Exactly
        }
    }

    # ------------------------------------------------------------------
    Context 'SSH polling - router DHCP IP discovery' {
    # ------------------------------------------------------------------
        # DHCP-mode router VMs have no ipAddress in their config; the
        # wait-for-SSH sub-step discovers the actual ext0 IP via Hyper-V
        # KVP integration services before probing SSH and writes the
        # discovered value back onto the VM def so the helper (and the
        # workload tunnel later, via _RouterVm.ipAddress) finds it via
        # the same object. This block lives in create-vm.ps1, not the
        # reachability helper, because it is a first-boot provisioning
        # concern.

        It 'delegates to Get-VmKvpIpAddress with the external switch name' {
            Initialize-HyperVMocks
            Mock Get-VmKvpIpAddress { '192.168.1.42' }
            # Capture the VM def the helper is asked to reach so we can
            # confirm the discovered KVP address was stamped onto it.
            $script:reachedVm = $null
            Mock Wait-VmSshAccessible {
                $script:reachedVm = $Vm
                [PSCustomObject]@{ Reachable = $true; ProbeIp = '192.168.1.42'; ProbePort = 22; ElapsedSeconds = 1 }
            }

            Invoke-VmCreation -Vm (New-DhcpRouterTestVm) -SwitchName 'External'

            Should -Invoke Get-VmKvpIpAddress -ParameterFilter {
                $VmName -eq 'router-01' -and
                $SwitchName -eq 'ExternalSwitch-Shared'
            }
            $script:reachedVm.ipAddress | Should -Be '192.168.1.42'
        }

        It 'writes the discovered IP back onto the VM def as ipAddress' {
            Initialize-HyperVMocks
            Mock Get-VmKvpIpAddress { '192.168.42.99' }

            $vm = New-DhcpRouterTestVm
            Invoke-VmCreation -Vm $vm -SwitchName 'External'

            # Workload code path reads $vm._RouterVm.ipAddress, which is
            # the same object. Adding the field via Add-Member is what
            # makes the discovery observable to downstream code.
            $vm.PSObject.Properties['ipAddress'] | Should -Not -BeNullOrEmpty
            $vm.ipAddress                        | Should -Be '192.168.42.99'
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
            # New-RouterTestVm carries ipAddress = '192.168.1.10', so the
            # discovery branch is bypassed. Mock Get-VmKvpIpAddress
            # registers the function with Pester (required for Should
            # -Invoke even at -Times 0) so a regression that re-introduces
            # a call is caught here.
            Initialize-HyperVMocks
            Mock Get-VmKvpIpAddress { '192.168.0.0' }

            Invoke-VmCreation -Vm (New-RouterTestVm) -SwitchName 'External'

            Should -Invoke Get-VmKvpIpAddress -Times 0 -Exactly
        }
    }

    # ------------------------------------------------------------------
    Context 'finally block - cleanup' {
    # ------------------------------------------------------------------
        # The seed ISO contains the plaintext password and must never
        # persist on the host disk after provisioning; the serial-console
        # reader must always be stopped. Wait-VmSshAccessible owns tunnel
        # disposal, so create-vm's finally covers only the serial-console
        # + seed-ISO teardown, which must run whether wait-for-SSH
        # succeeded or timed out.

        It 'stops the serial console and removes the seed ISO on timeout' {
            Initialize-HyperVMocks
            Mock Wait-VmSshAccessible {
                [PSCustomObject]@{ Reachable = $false; ProbeIp = '192.168.1.10'; ProbePort = 22; ElapsedSeconds = 600 }
            }

            { Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN' } |
                Should -Throw

            Should -Invoke Stop-SerialConsoleCapture -Times 1 -Exactly
            Should -Invoke Remove-VmSeedIso -Times 1 -Exactly -ParameterFilter {
                $VmName      -eq 'node-01' -and
                $SeedIsoPath -eq 'C:\VMs\node-01\node-01-seed.iso'
            }
        }

        It 'stops the serial console and removes the seed ISO on success' {
            # Mirror test for the happy path - the cleanup must NOT be
            # conditional on the reachability outcome.
            Initialize-HyperVMocks

            Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN'

            Should -Invoke Stop-SerialConsoleCapture -Times 1 -Exactly
            Should -Invoke Remove-VmSeedIso -Times 1 -Exactly -ParameterFilter {
                $VmName      -eq 'node-01' -and
                $SeedIsoPath -eq 'C:\VMs\node-01\node-01-seed.iso'
            }
        }
    }
}
