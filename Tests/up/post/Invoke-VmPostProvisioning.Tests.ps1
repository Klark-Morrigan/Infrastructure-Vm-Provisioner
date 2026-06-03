BeforeAll {
    # ---- Why this file uses global stubs instead of Pester Mock ------------
    # Invoke-VmPostProvisioning wraps its per-VM work in a scriptblock
    # frozen with .GetNewClosure() so the orchestrator's locals survive
    # the trip into Infrastructure.HyperV's Invoke-WithVmFileServer
    # (another module's session state). The closure captures the
    # orchestrator file's session state at closure-creation time; command
    # resolution from inside the closure does not walk back into Pester's
    # per-container scope, so Mocks declared in BeforeEach never intercept
    # the inner calls.
    #
    # The functions inside the closure (New-VmSshClient,
    # Invoke-SshClientCommand, Copy-VmFiles, Set-EnvironmentVariables,
    # plus the reconciler entry points) are therefore defined as GLOBAL
    # stubs that record their invocations into a $global: log. Tests
    # read the log directly. The outer call (Invoke-WithVmFileServer)
    # runs from the orchestrator function's own scope, which DOES see
    # global stubs - the stub there forwards to the captured scriptblock
    # so the closure executes in-process.
    # ----------------------------------------------------------------------

    # Auto-loading of the real Infrastructure.HyperV would shadow these
    # global stubs because module-exported functions win over plain
    # session functions. Remove anything already loaded and disable
    # auto-load for the duration of the file. Both reads are defensive
    # under StrictMode.
    Remove-Module Infrastructure.HyperV -Force -ErrorAction SilentlyContinue
    $prior = Get-Variable -Name PSModuleAutoLoadingPreference -Scope Global `
        -ErrorAction SilentlyContinue
    $script:_priorAutoLoad = if ($null -ne $prior) { $prior.Value } else { $null }
    $global:PSModuleAutoLoadingPreference = 'None'

    # Global invocation log + reset helper. Reset is called from BeforeEach
    # in the Describe below.
    $global:_PostProv_Calls = @{
        'New-VmSshClient'                  = @()
        'Invoke-SshClientCommand'          = @()
        'Copy-VmFiles'                     = @()
        'Copy-VmFilesByPattern'            = @()
        'Invoke-WithVmFileServer'          = @()
        'Set-EnvironmentVariables'         = @()
        'Initialize-VmManifestStore'       = @()
        'Get-Providers'                    = @()
        'Invoke-ToolchainReconciliation'   = @()
    }
    function global:Reset-PostProvCallLog {
        foreach ($k in @($global:_PostProv_Calls.Keys)) {
            $global:_PostProv_Calls[$k] = @()
        }
    }

    # Fake transport handles. The orchestrator only inspects ScriptMethod
    # surfaces (Disconnect / Dispose, IsConnected); no real state needed.
    $global:_PostProv_FakeSshClient = [PSCustomObject]@{ IsConnected = $false }
    $global:_PostProv_FakeSshClient | Add-Member -MemberType ScriptMethod -Name 'Disconnect' -Value {}
    $global:_PostProv_FakeSshClient | Add-Member -MemberType ScriptMethod -Name 'Dispose'    -Value {}

    $global:_PostProv_FakeServer = [PSCustomObject]@{
        BaseUrl    = 'http://192.168.1.1:8745'
        StagingDir = 'C:\Users\Public\file-server-stage'
    }

    # Toggle: when set, Invoke-SshClientCommand returns ExitStatus=1
    # instead of 0 so the "non-zero cloud-init" test can exercise that
    # branch without Mock.
    $global:_PostProv_SshExitStatus = 0

    # ---- Global stubs ----------------------------------------------------

    # Outer (orchestrator-scope) stub. Forwards to the captured scriptblock
    # so the closure executes in-process and records its own calls below.
    function global:Invoke-WithVmFileServer {
        param($VmIpAddress, $Port, [scriptblock]$ScriptBlock)
        $global:_PostProv_Calls['Invoke-WithVmFileServer'] += @{
            VmIpAddress = $VmIpAddress
            Port        = $Port
        }
        & $ScriptBlock $global:_PostProv_FakeServer
    }

    # PSSA's plain-text password warning is suppressed for the same reason
    # it is on the real cmdlet - SSH.NET requires a plain string.
    # -Timeout added to mirror the real cmdlet's public surface
    # (Infrastructure.HyperV 0.10.0+); tests do not assert on it so the
    # stub accepts and ignores it.
    function global:New-VmSshClient {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSAvoidUsingPlainTextForPassword', 'Password')]
        param($IpAddress, $Username, $Password, $Timeout)
        $global:_PostProv_Calls['New-VmSshClient'] += @{
            IpAddress = $IpAddress
            Username  = $Username
            Password  = $Password
        }
        return $global:_PostProv_FakeSshClient
    }

    function global:Invoke-SshClientCommand {
        param($SshClient, $Command)
        $global:_PostProv_Calls['Invoke-SshClientCommand'] += @{
            Command = $Command
        }
        [PSCustomObject]@{
            ExitStatus = $global:_PostProv_SshExitStatus
            Output     = ''
            Error      = ''
        }
    }

    function global:Copy-VmFiles {
        param($SshClient, $Server, $Entries)
        $global:_PostProv_Calls['Copy-VmFiles'] += @{ Entries = $Entries }
    }

    function global:Set-EnvironmentVariables {
        param($SshClient, $Vm)
        $global:_PostProv_Calls['Set-EnvironmentVariables'] += @{ Vm = $Vm }
    }

    function global:Initialize-VmManifestStore {
        param($SshClient)
        $global:_PostProv_Calls['Initialize-VmManifestStore'] += @{
            SshClient = $SshClient
        }
    }

    # Default: returns one no-op provider so the orchestrator can pass
    # the array through to Invoke-ToolchainReconciliation unchanged.
    # Tests that need a specific provider list override the function
    # locally.
    function global:Get-Providers {
        param($Vm)
        $global:_PostProv_Calls['Get-Providers'] += @{ Vm = $Vm }
        return @()
    }

    function global:Invoke-ToolchainReconciliation {
        # -OnProviderComplete added in the sub-step timing feature; the
        # stub accepts it so the orchestrator's call site stays exercised
        # but the callback is not invoked here (the dispatch tests do not
        # assert per-provider timing, which has its own test file).
        param($SshClient, $Server, $Vm, $Providers, $OnProviderComplete)
        $global:_PostProv_Calls['Invoke-ToolchainReconciliation'] += @{
            Vm        = $Vm
            Providers = $Providers
        }
    }

    # Sub-step timer stubs. The orchestrator captures these via
    # ${function:Invoke-WithSubStepTimer} / ${function:Add-SubStepDuration}
    # at the top of its closure; if they are not defined globally,
    # the captured variables are $null and `& $captured` fails with
    # "expression after '&' produced an object that was not valid".
    # The Invoke-WithSubStepTimer stub forwards directly to the action
    # so the dispatch tests still see the inner calls. Add-SubStepDuration
    # is a no-op here because these tests do not assert timing data.
    function global:Invoke-WithSubStepTimer {
        param($Parent, $Name, [scriptblock] $Action)
        & $Action
    }
    function global:Add-SubStepDuration {
        param($Parent, $Name, $ElapsedMs, [switch] $Failed)
    }

    # TODO(diagnostic, remove): stubs for the diagnostic helpers captured
    # by the orchestrator via ${function:...}. Same null-capture failure
    # mode as the timer stubs above. The SSH wrapper stub passes the
    # real client straight through so the orchestrator's downstream
    # consumers still observe the fake SshClient the tests injected.
    function global:Invoke-CloudInitDiagnostics {
        param($SshClient, $VmConfigPath, $VmName, $Timestamp)
    }
    function global:New-DiagnosticSshClientWrapper {
        param($RealClient, $VmConfigPath, $VmName, $Timestamp)
        return $RealClient
    }

    function global:Copy-VmFilesByPattern {
        param($SshClient, $Server, $Pattern, $TargetDir,
              [switch]$Recurse, [switch]$PreserveRelativePath)
        $global:_PostProv_Calls['Copy-VmFilesByPattern'] += @{
            Pattern              = $Pattern
            TargetDir            = $TargetDir
            Recurse              = [bool]$Recurse
            PreserveRelativePath = [bool]$PreserveRelativePath
        }
    }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\post\Invoke-VmPostProvisioning.ps1"

    function New-PlainVm {
        [PSCustomObject]@{
            vmName    = 'node-01'
            ipAddress = '192.168.1.10'
            username  = 'admin'
            password  = 'unit-test-password-not-real'
        }
    }

    function New-VmWithJdk {
        $vm = New-PlainVm
        Add-Member -InputObject $vm -MemberType NoteProperty -Name 'javaDevKit' `
            -Value ([PSCustomObject]@{ vendor = 'temurin'; version = '21' })
        $vm
    }

    function New-VmWithFiles {
        $vm = New-PlainVm
        Add-Member -InputObject $vm -MemberType NoteProperty -Name 'files' -Value @(
            [PSCustomObject]@{ source = 'C:\src\a'; target = '/opt/a' }
        )
        $vm
    }

    function New-VmWithBulkFile {
        $vm = New-PlainVm
        Add-Member -InputObject $vm -MemberType NoteProperty -Name 'files' -Value @(
            [PSCustomObject]@{ pattern = 'C:\jars\*.jar'; targetDir = '/opt/ci-jars' }
        )
        $vm
    }

    function New-VmWithBulkFileAllSwitches {
        $vm = New-PlainVm
        Add-Member -InputObject $vm -MemberType NoteProperty -Name 'files' -Value @(
            [PSCustomObject]@{
                pattern              = 'C:\jars\*.jar'
                targetDir            = '/opt/ci-jars'
                recurse              = $true
                preserveRelativePath = $true
            }
        )
        $vm
    }

    function New-VmWithEnvVars {
        $vm = New-PlainVm
        Add-Member -InputObject $vm -MemberType NoteProperty -Name 'envVars' -Value (
            [PSCustomObject]@{
                blockName = 'ci-01-app'
                entries   = @(
                    [PSCustomObject]@{ name = 'FOO_HOME'; value = '/opt/foo' }
                )
            }
        )
        $vm
    }

    function New-VmWithEmptyEnvVarsEntries {
        $vm = New-PlainVm
        Add-Member -InputObject $vm -MemberType NoteProperty -Name 'envVars' -Value (
            [PSCustomObject]@{
                blockName = 'ci-01-app'
                entries   = @()
            }
        )
        $vm
    }

    function New-VmWithMixedFiles {
        $vm = New-PlainVm
        Add-Member -InputObject $vm -MemberType NoteProperty -Name 'files' -Value @(
            [PSCustomObject]@{ source = 'C:\src\a'; target = '/opt/a' },
            [PSCustomObject]@{ pattern = 'C:\jars\*.jar'; targetDir = '/opt/ci-jars' },
            [PSCustomObject]@{ source = 'C:\src\b'; target = '/opt/b' }
        )
        $vm
    }
}

AfterAll {
    foreach ($name in @(
            'Invoke-WithVmFileServer', 'New-VmSshClient',
            'Invoke-SshClientCommand',
            'Copy-VmFiles', 'Copy-VmFilesByPattern',
            'Set-EnvironmentVariables',
            'Initialize-VmManifestStore', 'Get-Providers',
            'Invoke-ToolchainReconciliation',
            'Reset-PostProvCallLog')) {
        Remove-Item -Path "function:global:$name" -ErrorAction SilentlyContinue
    }
    foreach ($name in @(
            '_PostProv_Calls', '_PostProv_FakeSshClient',
            '_PostProv_FakeServer', '_PostProv_SshExitStatus')) {
        Remove-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue
    }

    $priorVar = Get-Variable -Name _priorAutoLoad -Scope Script `
        -ErrorAction SilentlyContinue
    $prior = if ($null -ne $priorVar) { $priorVar.Value } else { $null }
    if ($null -eq $prior) {
        Remove-Variable -Name PSModuleAutoLoadingPreference -Scope Global `
            -ErrorAction SilentlyContinue
    } else {
        $global:PSModuleAutoLoadingPreference = $prior
    }
}

Describe 'Invoke-VmPostProvisioning' {

    BeforeEach {
        Reset-PostProvCallLog
        $global:_PostProv_SshExitStatus = 0
    }

    Context 'no opt-in fields' {

        It 'is a no-op when none of files, javaDevKit, envVars is set' {
            Invoke-VmPostProvisioning -Vm (New-PlainVm)

            $global:_PostProv_Calls['Invoke-WithVmFileServer'].Count | Should -Be 0
            $global:_PostProv_Calls['New-VmSshClient'].Count         | Should -Be 0
        }

        It 'is a no-op when files is an empty array' {
            $vm = New-PlainVm
            Add-Member -InputObject $vm -MemberType NoteProperty -Name 'files' -Value @()

            Invoke-VmPostProvisioning -Vm $vm

            $global:_PostProv_Calls['Invoke-WithVmFileServer'].Count | Should -Be 0
        }
    }

    Context 'one or more opt-in fields' {

        It 'opens the file server with the VM IP' {
            Invoke-VmPostProvisioning -Vm (New-VmWithJdk)

            $calls = $global:_PostProv_Calls['Invoke-WithVmFileServer']
            $calls.Count | Should -Be 1
            $calls[0].VmIpAddress | Should -Be '192.168.1.10'
        }

        It 'connects SSH as the admin user with the VM password' {
            Invoke-VmPostProvisioning -Vm (New-VmWithJdk)

            $calls = $global:_PostProv_Calls['New-VmSshClient']
            $calls.Count | Should -Be 1
            $calls[0].IpAddress | Should -Be '192.168.1.10'
            $calls[0].Username  | Should -Be 'admin'
            $calls[0].Password  | Should -Be 'unit-test-password-not-real'
        }

        It 'waits for cloud-init exactly once, capped with timeout(1)' {
            Invoke-VmPostProvisioning -Vm (New-VmWithJdk)

            $calls = $global:_PostProv_Calls['Invoke-SshClientCommand']
            $calls.Count | Should -Be 1
            $calls[0].Command | Should -Match '^timeout \d+ cloud-init status --wait'
        }

        It 'opens the file server when javaDevKit is set even with no other opt-in field' {
            # The reconciler owns javaDevKit. Field presence (install or
            # ensure-none) is enough to warrant opening the transport;
            # the reconciler decides install vs uninstall from the
            # desired/installed diff.
            Invoke-VmPostProvisioning -Vm (New-VmWithJdk)
            $global:_PostProv_Calls['Invoke-WithVmFileServer'].Count | Should -Be 1
        }

        It 'opens the file server when javaDevKit is null (reconciler ensure-none)' {
            # "Remove the JDK" is now expressed as javaDevKit: null, which
            # the reconciler turns into uninstall. The orchestrator must
            # still pay the transport open.
            $vm = New-PlainVm
            Add-Member -InputObject $vm -MemberType NoteProperty -Name 'javaDevKit' -Value $null
            Invoke-VmPostProvisioning -Vm $vm
            $global:_PostProv_Calls['Invoke-WithVmFileServer'].Count | Should -Be 1
        }

        It 'dispatches Copy-VmFiles when files is set, passing -Entries' {
            Invoke-VmPostProvisioning -Vm (New-VmWithFiles)

            $calls = $global:_PostProv_Calls['Copy-VmFiles']
            $calls.Count | Should -Be 1
            # Orchestrator must translate $Vm.files (source/target lowercase)
            # into the module's Source/Target entry shape.
            @($calls[0].Entries).Count    | Should -Be 1
            $calls[0].Entries[0].Source   | Should -Be 'C:\src\a'
            $calls[0].Entries[0].Target   | Should -Be '/opt/a'
        }

        It 'does NOT dispatch Copy-VmFiles when files is absent' {
            Invoke-VmPostProvisioning -Vm (New-VmWithJdk)
            $global:_PostProv_Calls['Copy-VmFiles'].Count          | Should -Be 0
            $global:_PostProv_Calls['Copy-VmFilesByPattern'].Count | Should -Be 0
        }

        It 'dispatches Copy-VmFilesByPattern (not Copy-VmFiles) for a bulk entry' {
            # Defaults for optional booleans are applied at the dispatch
            # site, not in the validator, so an entry without them must
            # still surface as $false to the transport.
            Invoke-VmPostProvisioning -Vm (New-VmWithBulkFile)

            $bulk = $global:_PostProv_Calls['Copy-VmFilesByPattern']
            $bulk.Count                  | Should -Be 1
            $bulk[0].Pattern             | Should -Be 'C:\jars\*.jar'
            $bulk[0].TargetDir           | Should -Be '/opt/ci-jars'
            $bulk[0].Recurse             | Should -Be $false
            $bulk[0].PreserveRelativePath | Should -Be $false
            $global:_PostProv_Calls['Copy-VmFiles'].Count | Should -Be 0
        }

        It 'forwards recurse / preserveRelativePath when set on a bulk entry' {
            Invoke-VmPostProvisioning -Vm (New-VmWithBulkFileAllSwitches)

            $bulk = $global:_PostProv_Calls['Copy-VmFilesByPattern']
            $bulk.Count                   | Should -Be 1
            $bulk[0].Recurse              | Should -Be $true
            $bulk[0].PreserveRelativePath | Should -Be $true
        }

        It 'dispatches mixed [single, bulk, single] entries in JSON order' {
            # JSON order is the contract the dispatch loop preserves; both
            # transports share the same SSH session, so there is no
            # batching win to chase by grouping by form.
            $originalCopy = ${function:global:Copy-VmFiles}
            $originalBulk = ${function:global:Copy-VmFilesByPattern}
            $global:_PostProv_Order = @()
            ${function:global:Copy-VmFiles} = {
                param($SshClient, $Server, $Entries)
                $global:_PostProv_Order += "single:$($Entries[0].Source)"
            }
            ${function:global:Copy-VmFilesByPattern} = {
                param($SshClient, $Server, $Pattern, $TargetDir,
                      [switch]$Recurse, [switch]$PreserveRelativePath)
                $global:_PostProv_Order += "bulk:$Pattern"
            }
            try {
                Invoke-VmPostProvisioning -Vm (New-VmWithMixedFiles)
                $global:_PostProv_Order | Should -Be @(
                    'single:C:\src\a',
                    'bulk:C:\jars\*.jar',
                    'single:C:\src\b'
                )
            }
            finally {
                ${function:global:Copy-VmFiles}          = $originalCopy
                ${function:global:Copy-VmFilesByPattern} = $originalBulk
                Remove-Variable -Name _PostProv_Order -Scope Global -ErrorAction SilentlyContinue
            }
        }

        It 'propagates Copy-VmFilesByPattern failures and still disposes the SSH client' {
            # Simulates the resolver's zero-match / collision errors, which
            # throw before any SSH I/O for the entry. The orchestrator's
            # finally block must still tear down the SSH session.
            $vm = New-VmWithBulkFile
            $originalBulk = ${function:global:Copy-VmFilesByPattern}
            $script:_DisposedClient = $null
            $global:_PostProv_FakeSshClient | Add-Member -MemberType ScriptMethod `
                -Name 'Dispose' -Force -Value { $script:_DisposedClient = $true }
            ${function:global:Copy-VmFilesByPattern} = {
                param($SshClient, $Server, $Pattern, $TargetDir,
                      [switch]$Recurse, [switch]$PreserveRelativePath)
                throw "resolver: pattern '$Pattern' matched zero files"
            }
            try {
                { Invoke-VmPostProvisioning -Vm $vm } |
                    Should -Throw -ExpectedMessage '*matched zero files*'
                $script:_DisposedClient | Should -Be $true
            }
            finally {
                ${function:global:Copy-VmFilesByPattern} = $originalBulk
                $global:_PostProv_FakeSshClient | Add-Member -MemberType ScriptMethod `
                    -Name 'Dispose' -Force -Value {}
                Remove-Variable -Name _DisposedClient -Scope Script -ErrorAction SilentlyContinue
            }
        }

        It 'dispatches Copy-VmFiles before the reconciler when both are set' {
            # Stylistic ordering only - steps are self-contained, but the
            # orchestrator commits to this order so output is predictable.
            $vm = New-VmWithJdk
            Add-Member -InputObject $vm -MemberType NoteProperty -Name 'files' -Value @(
                [PSCustomObject]@{ source = 'C:\src\a'; target = '/opt/a' }
            )

            $originalCopy = ${function:global:Copy-VmFiles}
            $originalRec  = ${function:global:Invoke-ToolchainReconciliation}
            $global:_PostProv_Order = @()
            ${function:global:Copy-VmFiles} = { param($SshClient, $Server, $Entries) $global:_PostProv_Order += 'files' }
            ${function:global:Invoke-ToolchainReconciliation} = {
                param($SshClient, $Server, $Vm, $Providers)
                $global:_PostProv_Order += 'reconcile'
            }
            try {
                Invoke-VmPostProvisioning -Vm $vm
                $global:_PostProv_Order | Should -Be @('files', 'reconcile')
            }
            finally {
                ${function:global:Copy-VmFiles}                   = $originalCopy
                ${function:global:Invoke-ToolchainReconciliation} = $originalRec
                Remove-Variable -Name _PostProv_Order -Scope Global -ErrorAction SilentlyContinue
            }
        }

        It 'does NOT dispatch Set-EnvironmentVariables when envVars is absent' {
            # Regression guard: the new dispatch branch must be opt-in.
            Invoke-VmPostProvisioning -Vm (New-VmWithJdk)
            $global:_PostProv_Calls['Set-EnvironmentVariables'].Count | Should -Be 0
        }

        It 'dispatches Set-EnvironmentVariables when envVars is the only opt-in field' {
            Invoke-VmPostProvisioning -Vm (New-VmWithEnvVars)

            $calls = $global:_PostProv_Calls['Set-EnvironmentVariables']
            $calls.Count                | Should -Be 1
            $calls[0].Vm.envVars.blockName | Should -Be 'ci-01-app'
            @($calls[0].Vm.envVars.entries).Count | Should -Be 1
        }

        It 'still opens the file server and SSH for an envVars-only VM' {
            # Plan decision: an envVars-only VM still opens the file server
            # because the existing always-open contract is what every other
            # branch relies on. Changing that contract is a separate cleanup.
            Invoke-VmPostProvisioning -Vm (New-VmWithEnvVars)
            $global:_PostProv_Calls['Invoke-WithVmFileServer'].Count | Should -Be 1
            $global:_PostProv_Calls['New-VmSshClient'].Count         | Should -Be 1
        }

        It 'routes envVars.entries: @() through to the wrapper as-is' {
            # Empty entries is the operator's "remove the managed block"
            # intent; the orchestrator must not second-guess it.
            Invoke-VmPostProvisioning -Vm (New-VmWithEmptyEnvVarsEntries)

            $calls = $global:_PostProv_Calls['Set-EnvironmentVariables']
            $calls.Count                            | Should -Be 1
            @($calls[0].Vm.envVars.entries).Count   | Should -Be 0
            $calls[0].Vm.envVars.blockName          | Should -Be 'ci-01-app'
        }

        It 'dispatches files -> reconciler -> envVars when all three are set' {
            $vm = New-VmWithEnvVars
            Add-Member -InputObject $vm -MemberType NoteProperty -Name 'javaDevKit' `
                -Value ([PSCustomObject]@{ vendor = 'temurin'; version = '21' })
            Add-Member -InputObject $vm -MemberType NoteProperty -Name 'files' -Value @(
                [PSCustomObject]@{ source = 'C:\src\a'; target = '/opt/a' }
            )

            $originalCopy = ${function:global:Copy-VmFiles}
            $originalRec  = ${function:global:Invoke-ToolchainReconciliation}
            $originalEnv  = ${function:global:Set-EnvironmentVariables}
            $global:_PostProv_Order = @()
            ${function:global:Copy-VmFiles}             = { param($SshClient, $Server, $Entries) $global:_PostProv_Order += 'files' }
            ${function:global:Invoke-ToolchainReconciliation} = {
                param($SshClient, $Server, $Vm, $Providers)
                $global:_PostProv_Order += 'reconcile'
            }
            ${function:global:Set-EnvironmentVariables} = { param($SshClient, $Vm)               $global:_PostProv_Order += 'envVars' }
            try {
                Invoke-VmPostProvisioning -Vm $vm
                $global:_PostProv_Order | Should -Be @('files', 'reconcile', 'envVars')
            }
            finally {
                ${function:global:Copy-VmFiles}                   = $originalCopy
                ${function:global:Invoke-ToolchainReconciliation} = $originalRec
                ${function:global:Set-EnvironmentVariables}       = $originalEnv
                Remove-Variable -Name _PostProv_Order -Scope Global -ErrorAction SilentlyContinue
            }
        }

        It 'propagates Set-EnvironmentVariables failures and still disposes the SSH client' {
            $originalEnv = ${function:global:Set-EnvironmentVariables}
            $script:_DisposedClient = $null
            $global:_PostProv_FakeSshClient | Add-Member -MemberType ScriptMethod `
                -Name 'Dispose' -Force -Value { $script:_DisposedClient = $true }
            ${function:global:Set-EnvironmentVariables} = {
                param($SshClient, $Vm)
                throw "Set-EnvironmentVariables failed on $($Vm.vmName): boom"
            }
            try {
                { Invoke-VmPostProvisioning -Vm (New-VmWithEnvVars) } |
                    Should -Throw -ExpectedMessage '*Set-EnvironmentVariables failed on node-01*'
                $script:_DisposedClient | Should -Be $true
            }
            finally {
                ${function:global:Set-EnvironmentVariables} = $originalEnv
                $global:_PostProv_FakeSshClient | Add-Member -MemberType ScriptMethod `
                    -Name 'Dispose' -Force -Value {}
                Remove-Variable -Name _DisposedClient -Scope Script -ErrorAction SilentlyContinue
            }
        }

        It 'initialises the manifest store exactly once per VM' {
            # Manifest store init runs near the top of the per-VM loop,
            # unconditionally (the cost is one mkdir + chown + chmod and
            # owning the directory's lifecycle here keeps future providers
            # from having to bootstrap it themselves).
            Invoke-VmPostProvisioning -Vm (New-VmWithJdk)
            $global:_PostProv_Calls['Initialize-VmManifestStore'].Count | Should -Be 1
        }

        It 'invokes the reconciler exactly once per VM, passing the VM through Get-Providers' {
            Invoke-VmPostProvisioning -Vm (New-VmWithJdk)

            $calls = $global:_PostProv_Calls['Invoke-ToolchainReconciliation']
            $calls.Count                | Should -Be 1
            $calls[0].Vm.vmName          | Should -Be 'node-01'

            $providerCalls = $global:_PostProv_Calls['Get-Providers']
            $providerCalls.Count          | Should -Be 1
            $providerCalls[0].Vm.vmName   | Should -Be 'node-01'
        }

        It 'does not dispatch any Install-Jdk / Uninstall-Jdk step function' {
            # The reconciler-owned JdkProvider replaces direct step
            # dispatch. A regression that re-adds an Install-Jdk /
            # Uninstall-Jdk function would shadow the reconciler's
            # manifest-driven path.
            Invoke-VmPostProvisioning -Vm (New-VmWithJdk)
            (Get-Command -Name Install-Jdk -ErrorAction SilentlyContinue) |
                Should -BeNullOrEmpty
            (Get-Command -Name Uninstall-Jdk -ErrorAction SilentlyContinue) |
                Should -BeNullOrEmpty
        }

        It 'runs Initialize-VmManifestStore before the reconciler' {
            # The store must exist before any provider tries to write a
            # manifest into it.
            $vm = New-VmWithJdk

            $originalInit  = ${function:global:Initialize-VmManifestStore}
            $originalRec   = ${function:global:Invoke-ToolchainReconciliation}
            $global:_PostProv_Order = @()
            ${function:global:Initialize-VmManifestStore} = {
                param($SshClient)
                $global:_PostProv_Order += 'init-store'
            }
            ${function:global:Invoke-ToolchainReconciliation} = {
                param($SshClient, $Server, $Vm, $Providers)
                $global:_PostProv_Order += 'reconcile'
            }
            try {
                Invoke-VmPostProvisioning -Vm $vm
                $global:_PostProv_Order | Should -Be @('init-store', 'reconcile')
            }
            finally {
                ${function:global:Initialize-VmManifestStore}     = $originalInit
                ${function:global:Invoke-ToolchainReconciliation} = $originalRec
                Remove-Variable -Name _PostProv_Order -Scope Global -ErrorAction SilentlyContinue
            }
        }

        It 'still dispatches steps when cloud-init wait reports non-zero' {
            # Non-zero cloud-init status is most often unrelated to our
            # steps - dispatch and let downstream assertions catch real
            # problems.
            $global:_PostProv_SshExitStatus = 1

            Invoke-VmPostProvisioning -Vm (New-VmWithJdk)

            $global:_PostProv_Calls['Invoke-ToolchainReconciliation'].Count | Should -Be 1
        }
    }
}
