BeforeAll {
    # Stub Hyper-V / networking cmdlets unavailable outside a Hyper-V
    # host so the helper can be dot-sourced and the cmdlets mocked.
    # Stubs return nothing; per-test Mocks supply the per-case fakes.
    function Get-VM                 { param([string]$Name, $ErrorAction) }
    function Get-VMNetworkAdapter   { param([string]$VMName, $ErrorAction) }
    function Get-NetIPConfiguration { param([string]$InterfaceAlias, $ErrorAction) }
    function Get-NetNeighbor        { param([string]$IPAddress, $ErrorAction) }
    function Get-NetRoute           { param([string]$DestinationPrefix, $ErrorAction) }

    # Stubs for the SSH-side dependency chain. Invoke-VmRuntimeDiag's
    # guest-side branch goes through these; tests that exercise the
    # branch mock them per-It.
    function New-VmSshClientWithJump { param($Vm, $Timeout) }
    function Invoke-SshClientCommand { param($SshClient, $Command) }

    # Get-VmDiagFolder is a pure path helper - dot-source the real one
    # rather than stub, so the orchestrator's path-shape assertions
    # exercise the actual contract.
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\common\diag\Get-VmDiagFolder.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\common\diag\Invoke-VmRuntimeDiag.ps1"

    function New-TestVm {
        [PSCustomObject]@{
            vmName       = 'router-e2e'
            vmConfigPath = 'TestDrive:\config'
            ipAddress    = '192.168.137.10'
        }
    }

    function New-TestVmAdapter {
        param(
            [string]   $SwitchName = 'ExternalSwitch-Shared',
            [string[]] $IPAddresses = @('192.168.137.50'),
            [string]   $MacAddress = '020AB2FED200'
        )
        [PSCustomObject]@{
            Name        = 'Network Adapter'
            SwitchName  = $SwitchName
            IPAddresses = $IPAddresses
            MacAddress  = $MacAddress
            Status      = @('Ok')
        }
    }
}

Describe 'Get-VmRuntimeDiagHostSide' {

    BeforeEach {
        $script:diagDir = Join-Path 'TestDrive:\' ([Guid]::NewGuid().Guid)
        New-Item -ItemType Directory -Path $script:diagDir | Out-Null
        $script:logPath = Join-Path $script:diagDir 'runtime-diag.log'
        # Mock arp -a so the test does not shell out to the real one.
        # Pester cannot mock native commands directly; the helper calls
        # the literal `arp` so we shadow it with a function stub of the
        # same name and Mock that.
        function arp { param([string]$Switches) "arp-output-stub" }
        Mock arp { 'arp-output-stub' }
    }

    It 'writes a host-side header banner to the output file' {
        Mock Get-VM               { [PSCustomObject]@{ Name = 'router-e2e'; State = 'Running'; Uptime = '00:30:00' } }
        Mock Get-VMNetworkAdapter { @(New-TestVmAdapter) }
        Mock Get-NetIPConfiguration { }
        Mock Get-NetNeighbor        { }
        Mock Get-NetRoute           { }

        Get-VmRuntimeDiagHostSide -Vm (New-TestVm) -OutputPath $script:logPath

        $log = Get-Content $script:logPath -Raw
        $log | Should -Match "host-side runtime diag for 'router-e2e'"
    }

    It 'captures Get-VM and Get-VMNetworkAdapter output' {
        Mock Get-VM               { [PSCustomObject]@{ Name = 'router-e2e'; State = 'Running' } }
        Mock Get-VMNetworkAdapter { @(New-TestVmAdapter -IPAddresses @('192.168.137.50')) }
        Mock Get-NetIPConfiguration { }
        Mock Get-NetNeighbor        { }
        Mock Get-NetRoute           { }

        Get-VmRuntimeDiagHostSide -Vm (New-TestVm) -OutputPath $script:logPath

        Should -Invoke Get-VM               -Times 1 -Exactly -ParameterFilter { $Name -eq 'router-e2e' }
        Should -Invoke Get-VMNetworkAdapter -Times 1 -Exactly -ParameterFilter { $VMName -eq 'router-e2e' }

        $log = Get-Content $script:logPath -Raw
        $log | Should -Match '=== Get-VM ==='
        $log | Should -Match '=== Get-VMNetworkAdapter ==='
    }

    It 'queries the host vEthernet for each switch the VM is attached to' {
        Mock Get-VM               { [PSCustomObject]@{ Name = 'router-e2e' } }
        Mock Get-VMNetworkAdapter {
            @(
                New-TestVmAdapter -SwitchName 'ExternalSwitch-Shared'
                New-TestVmAdapter -SwitchName 'PrivateSwitch-E2E' `
                                  -IPAddresses @('10.99.0.1')
            )
        }
        Mock Get-NetIPConfiguration { }
        Mock Get-NetNeighbor        { }
        Mock Get-NetRoute           { }

        Get-VmRuntimeDiagHostSide -Vm (New-TestVm) -OutputPath $script:logPath

        Should -Invoke Get-NetIPConfiguration -Times 1 -Exactly `
            -ParameterFilter { $InterfaceAlias -eq 'vEthernet (ExternalSwitch-Shared)' }
        Should -Invoke Get-NetIPConfiguration -Times 1 -Exactly `
            -ParameterFilter { $InterfaceAlias -eq 'vEthernet (PrivateSwitch-E2E)' }
    }

    It 'queries Get-NetNeighbor for every IPv4 the VM has held' {
        Mock Get-VM               { [PSCustomObject]@{ Name = 'router-e2e' } }
        Mock Get-VMNetworkAdapter {
            @(New-TestVmAdapter -IPAddresses @(
                '192.168.137.50',
                '192.168.137.56',
                'fe80::a:b2ff:fefe:d200'  # IPv6 - must be skipped
            ))
        }
        Mock Get-NetIPConfiguration { }
        Mock Get-NetNeighbor        { }
        Mock Get-NetRoute           { }

        Get-VmRuntimeDiagHostSide -Vm (New-TestVm) -OutputPath $script:logPath

        Should -Invoke Get-NetNeighbor -Times 1 -Exactly -ParameterFilter { $IPAddress -eq '192.168.137.50' }
        Should -Invoke Get-NetNeighbor -Times 1 -Exactly -ParameterFilter { $IPAddress -eq '192.168.137.56' }
        Should -Invoke Get-NetNeighbor -Times 0 -ParameterFilter { $IPAddress -like 'fe80*' }
    }

    It 'queries Get-NetRoute for the /24 subnet derived from each IPv4' {
        Mock Get-VM               { [PSCustomObject]@{ Name = 'router-e2e' } }
        Mock Get-VMNetworkAdapter {
            @(New-TestVmAdapter -IPAddresses @('192.168.137.50', '10.99.0.1'))
        }
        Mock Get-NetIPConfiguration { }
        Mock Get-NetNeighbor        { }
        Mock Get-NetRoute           { }

        Get-VmRuntimeDiagHostSide -Vm (New-TestVm) -OutputPath $script:logPath

        Should -Invoke Get-NetRoute -Times 1 -Exactly -ParameterFilter { $DestinationPrefix -eq '192.168.137.0/24' }
        Should -Invoke Get-NetRoute -Times 1 -Exactly -ParameterFilter { $DestinationPrefix -eq '10.99.0.0/24' }
    }

    It 'skips the IP-derived sections when the VM has no IPv4 reported' {
        # Hyper-V integration services may report no IPs at all if the
        # VM has not booted far enough for the KVP daemon to publish.
        # The host-side capture should still complete (Get-VM/adapter
        # sections only) and not throw on the IP-walk loops.
        Mock Get-VM               { [PSCustomObject]@{ Name = 'router-e2e' } }
        Mock Get-VMNetworkAdapter { @(New-TestVmAdapter -IPAddresses @()) }
        Mock Get-NetIPConfiguration { }
        Mock Get-NetNeighbor        { }
        Mock Get-NetRoute           { }

        { Get-VmRuntimeDiagHostSide -Vm (New-TestVm) -OutputPath $script:logPath } |
            Should -Not -Throw

        Should -Invoke Get-NetNeighbor -Times 0
        Should -Invoke Get-NetRoute    -Times 0
    }

    It 'tolerates the VM being absent from Hyper-V (Get-VM returns nothing)' {
        # SilentlyContinue keeps Get-VM/Get-VMNetworkAdapter from
        # throwing when the VM is gone; the diag still emits its
        # banner and the empty captures so the operator sees "we
        # tried, nothing was there".
        Mock Get-VM               { }
        Mock Get-VMNetworkAdapter { }
        Mock Get-NetIPConfiguration { }
        Mock Get-NetNeighbor        { }
        Mock Get-NetRoute           { }

        { Get-VmRuntimeDiagHostSide -Vm (New-TestVm) -OutputPath $script:logPath } |
            Should -Not -Throw

        Get-Content $script:logPath -Raw | Should -Match 'host-side runtime diag'
    }
}

Describe 'Get-VmRuntimeDiagGuestSide' {

    BeforeEach {
        $script:diagDir = Join-Path 'TestDrive:\' ([Guid]::NewGuid().Guid)
        New-Item -ItemType Directory -Path $script:diagDir | Out-Null
        $script:logPath = Join-Path $script:diagDir 'runtime-diag.log'
    }

    It 'runs each capture command via Invoke-SshClientCommand and writes results' {
        $script:_invokedCommands = @()
        Mock Invoke-SshClientCommand {
            param($SshClient, $Command)
            $script:_invokedCommands += $Command
            [PSCustomObject]@{ Output = "stub-output-for: $Command"; ExitStatus = 0 }
        }

        $fakeClient = [PSCustomObject]@{ Connected = $true }
        Get-VmRuntimeDiagGuestSide -SshClient $fakeClient -OutputPath $script:logPath

        # All seven captures must have fired.
        $script:_invokedCommands.Count | Should -BeGreaterOrEqual 7

        # And every capture name should appear as a section header in
        # the log so an operator can grep for the section they want.
        $log = Get-Content $script:logPath -Raw
        foreach ($name in @('ip-addr', 'ip-route', 'ss-listen', 'resolv',
                             'nftables', 'networkd-recent', 'cloud-init-recent')) {
            $log | Should -Match "=== $name ==="
        }
    }

    It 'wraps each command in sh -c with merged stderr' {
        Mock Invoke-SshClientCommand {
            [PSCustomObject]@{ Output = 'x'; ExitStatus = 0 }
        }

        $fakeClient = [PSCustomObject]@{ Connected = $true }
        Get-VmRuntimeDiagGuestSide -SshClient $fakeClient -OutputPath $script:logPath

        # Spot-check: every call goes through sh -c '<body> 2>&1'.
        Should -Invoke Invoke-SshClientCommand -ParameterFilter {
            $Command -like "sh -c '*2>&1'"
        } -Times 7
    }
}

Describe 'Invoke-VmRuntimeDiag (orchestrator)' {

    BeforeEach {
        $script:baseDir = Join-Path 'TestDrive:\' ([Guid]::NewGuid().Guid)
        New-Item -ItemType Directory -Path $script:baseDir | Out-Null
    }

    It 'creates the per-VM per-timestamp diagnostics folder' {
        Mock Get-VmRuntimeDiagHostSide  { }
        Mock Get-VmRuntimeDiagGuestSide { }
        Mock New-VmSshClientWithJump    {
            [PSCustomObject]@{
                Client = [PSCustomObject]@{ Connected = $true }
            } | Add-Member -MemberType ScriptMethod -Name Dispose -Value { } -PassThru
        }

        $vm = [PSCustomObject]@{ vmName = 'router-e2e' }
        $diag = Invoke-VmRuntimeDiag -Vm           $vm `
                                     -VmConfigPath $script:baseDir `
                                     -Timestamp    '2026-06-10_16-00-00'

        $expected = Join-Path $script:baseDir 'diagnostics\router-e2e\2026-06-10_16-00-00'
        $diag | Should -Be $expected
        Test-Path -Path $expected -PathType Container | Should -BeTrue
    }

    It 'always calls Get-VmRuntimeDiagHostSide' {
        Mock Get-VmRuntimeDiagHostSide  { }
        Mock Get-VmRuntimeDiagGuestSide { }
        Mock New-VmSshClientWithJump    {
            [PSCustomObject]@{ Client = $null } |
                Add-Member -MemberType ScriptMethod -Name Dispose -Value { } -PassThru
        }

        $vm = [PSCustomObject]@{ vmName = 'router-e2e' }
        Invoke-VmRuntimeDiag -Vm $vm -VmConfigPath $script:baseDir | Out-Null

        Should -Invoke Get-VmRuntimeDiagHostSide -Times 1 -Exactly
    }

    It 'invokes the guest-side capture when SSH opens cleanly' {
        Mock Get-VmRuntimeDiagHostSide  { }
        Mock Get-VmRuntimeDiagGuestSide { }
        $disposed = $false
        Mock New-VmSshClientWithJump {
            $obj = [PSCustomObject]@{ Client = [PSCustomObject]@{ Connected = $true } }
            $obj | Add-Member -MemberType ScriptMethod -Name Dispose `
                              -Value { $script:_disposed = $true } -PassThru -Force
        }

        $vm = [PSCustomObject]@{ vmName = 'router-e2e' }
        Invoke-VmRuntimeDiag -Vm $vm -VmConfigPath $script:baseDir | Out-Null

        Should -Invoke Get-VmRuntimeDiagGuestSide -Times 1 -Exactly
    }

    It 'logs the SSH-open failure and returns the folder when SSH cannot connect' {
        Mock Get-VmRuntimeDiagHostSide  { }
        Mock Get-VmRuntimeDiagGuestSide { }
        Mock New-VmSshClientWithJump    { throw 'connection refused' }

        $vm = [PSCustomObject]@{ vmName = 'router-e2e' }
        $diag = Invoke-VmRuntimeDiag -Vm $vm -VmConfigPath $script:baseDir `
                                     -Timestamp '2026-06-10_16-00-00'

        $logPath = Join-Path $diag 'runtime-diag.log'
        $log = Get-Content $logPath -Raw
        $log | Should -Match 'guest-side capture skipped'
        $log | Should -Match 'connection refused'

        Should -Invoke Get-VmRuntimeDiagGuestSide -Times 0
    }

    It 'generates a timestamp when none is provided' {
        Mock Get-VmRuntimeDiagHostSide  { }
        Mock Get-VmRuntimeDiagGuestSide { }
        Mock New-VmSshClientWithJump    { throw 'irrelevant' }

        $vm = [PSCustomObject]@{ vmName = 'router-e2e' }
        $diag = Invoke-VmRuntimeDiag -Vm $vm -VmConfigPath $script:baseDir

        # Resulting path should be diagnostics\router-e2e\<yyyy-MM-dd_HH-mm-ss>\.
        $diag | Should -Match 'diagnostics\\router-e2e\\\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$'
    }
}
