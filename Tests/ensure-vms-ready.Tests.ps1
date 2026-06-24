<#
.SYNOPSIS
    Behavioural unit tests for ensure-vms-ready.ps1.

.DESCRIPTION
    ensure-vms-ready.ps1 is a thin orchestrator: read config, power the fleet
    on via Invoke-VmFleetPowerOn, then walk each environment router-first
    calling Wait-VmSshAccessible, aggregate per-VM readiness, and surface an
    exit code. Its dependencies have their own suites and are mocked here so
    this file pins only the orchestration logic that lives in the script:

      - power-on runs once with the parsed VM defs;
      - routers are waited before their workloads;
      - routers get -RouterVm $null, workloads get -RouterVm <router>;
      - an unreachable / power-on-failed router short-circuits its
        workloads with no Wait-VmSshAccessible call;
      - a single bad VM (power-on or readiness) does not strand the rest;
      - environments are independent (a dead router in one does not block
        another);
      - standalone environments (no router) probe each workload directly;
      - the aggregate bucket math survives single-match scalar unrolling;
      - exit 0 only when every VM is Ready, exit 1 otherwise.

    The per-VM Start-VmIfStopped loop belongs to Invoke-VmFleetPowerOn and
    the tunnel/banner logic to Wait-VmSshAccessible; their coverage lives in
    Tests/common/power/Invoke-VmFleetPowerOn.Tests.ps1 and
    Tests/common/ssh/Wait-VmSshAccessible.Tests.ps1.

    Harness: the script cannot be dot-sourced directly because its top-level
    body runs the orchestration as a side effect. As with start-vms.Tests.ps1
    a shimmed copy is written to a temp dir where every dot-source resolves to
    an empty stub file (the real behaviour is provided by Pester mocks against
    the function names defined in BeforeAll), and the terminal `exit (...)`
    line is rewritten to emit the chosen code to the pipeline so the test
    process is not terminated.

    Fixture data is inlined in each mock body rather than read from a
    `$script:` variable: mock bodies execute while `& $shimPath` is on the
    call stack, where `$script:` resolves to the shimmed script's scope, not
    this file's. The one piece of cross-boundary state we need - the order
    Wait-VmSshAccessible was called in - is recorded to a temp file whose
    path is derived from [IO.Path]::GetTempPath() identically on both sides.
#>

BeforeAll {
    $script:realPath = Join-Path $PSScriptRoot '..\hyper-v\ubuntu\ensure-vms-ready.ps1'

    # Sibling shim directory so $PSScriptRoot inside the script resolves to a
    # sandbox we control. Empty stub files satisfy every dot-source; the real
    # behaviour comes from the Pester mocks below.
    $script:shimDir = Join-Path ([IO.Path]::GetTempPath()) `
        ("ensure-vms-ready-test-" + [Guid]::NewGuid().ToString('N'))
    foreach ($sub in @('common\config', 'common\network', 'common\power', 'common\ssh')) {
        New-Item -ItemType Directory -Path (Join-Path $script:shimDir $sub) `
            -Force | Out-Null
    }
    foreach ($rel in @(
        'common\config\Group-VmsByEnvironment.ps1',
        'common\config\Read-VmProvisionerConfig.ps1',
        'common\network\Resolve-ExistingRouterIp.ps1',
        'common\power\Invoke-VmFleetPowerOn.ps1',
        'common\ssh\Wait-VmSshAccessible.ps1',
        'Install-ModuleDependencies.ps1'
    )) {
        Set-Content -LiteralPath (Join-Path $script:shimDir $rel) -Value '' `
            -Encoding UTF8
    }

    # The readiness-status chain (Resolve-VmReadinessStatus ->
    # Invoke-VmReadinessWait) is the orchestration this suite pins, so its
    # REAL files are copied into the shim rather than emptied. They bottom out
    # at Wait-VmSshAccessible, which stays an empty stub above so the call
    # resolves to the mocked test-scope function instead of the real probe.
    $ubuntuDir = Join-Path $PSScriptRoot '..\hyper-v\ubuntu'
    foreach ($rel in @(
        'common\ssh\Invoke-VmReadinessWait.ps1',
        'common\ssh\Resolve-VmReadinessStatus.ps1'
    )) {
        Copy-Item -LiteralPath (Join-Path $ubuntuDir $rel) `
            -Destination (Join-Path $script:shimDir $rel) -Force
    }

    # Rewrite the terminal `exit (...)` into a pipeline-emitted expression so
    # the chosen exit code is captured from `& $shimPath` instead of killing
    # the test process. `$$` in the .NET regex replacement yields a literal
    # `$` in the output.
    $raw  = Get-Content -Raw -LiteralPath $script:realPath
    $shim = $raw -replace `
        '(?m)^exit\s+\(.*\)\s*$', `
        '(($$ready -eq $$readiness.Count) ? 0 : 1)'
    Set-Content -LiteralPath (Join-Path $script:shimDir 'ensure-vms-ready.ps1') `
        -Value $shim -Encoding UTF8
    $script:shimPath = Join-Path $script:shimDir 'ensure-vms-ready.ps1'

    # Stub functions the script calls. Pester's Mock attaches by name; the
    # real implementations are covered by their own suites. Param blocks
    # declared so ParameterFilter can bind forwarded values.
    function Read-VmProvisionerConfig { param([string] $SecretSuffix) }
    function Invoke-VmFleetPowerOn    { param([object[]] $VmDefs) }
    function Group-VmsByEnvironment   { param([object[]] $VmDefs) }
    function Resolve-ExistingRouterIp { param([object] $RouterVm) }
    function Wait-VmSshAccessible {
        param(
            [object]      $Vm,
            [object]      $RouterVm,
            [datetime]    $Deadline,
            [scriptblock] $OnPoll
        )
    }

    $script:TestSuffix = 'Test'

    # Cross-boundary recorder for Wait-VmSshAccessible call order. Computed
    # from GetTempPath() so the mock (running under & $shimPath) and the test
    # assertions resolve the same file without sharing a $script: variable.
    $script:WaitOrderFile = Join-Path ([IO.Path]::GetTempPath()) `
        'ensure-vms-ready-waitorder.log'

    function Get-WaitOrder {
        if (Test-Path -LiteralPath $script:WaitOrderFile) {
            @(Get-Content -LiteralPath $script:WaitOrderFile)
        }
        else { @() }
    }

    function Invoke-EnsureVmsReady {
        # The shim emits the chosen exit code to the pipeline; capture it so
        # the test can inspect the code without the host being terminated.
        $script:exitCode = & $script:shimPath -SecretSuffix $script:TestSuffix
    }
}

AfterAll {
    if ($script:shimDir -and (Test-Path -LiteralPath $script:shimDir)) {
        Remove-Item -LiteralPath $script:shimDir -Recurse -Force `
            -ErrorAction SilentlyContinue
    }
}

Describe 'ensure-vms-ready.ps1 - orchestration' {

    BeforeEach {
        if (Test-Path -LiteralPath $script:WaitOrderFile) {
            Remove-Item -LiteralPath $script:WaitOrderFile -Force
        }

        Mock Read-VmProvisionerConfig { ,@() }
        Mock Invoke-VmFleetPowerOn {
            [PSCustomObject]@{ Transitions = @(); Failed = @() }
        }
        Mock Group-VmsByEnvironment   { @() }
        Mock Resolve-ExistingRouterIp { }
        # Default: every VM reachable. Records call order to the temp file so
        # router-first ordering can be asserted across the & $shimPath boundary.
        Mock Wait-VmSshAccessible {
            Add-Content -LiteralPath (Join-Path ([IO.Path]::GetTempPath()) `
                'ensure-vms-ready-waitorder.log') -Value $Vm.vmName
            [PSCustomObject]@{ Reachable = $true }
        }
        Mock Write-Host { }
    }

    Context 'happy path - one env, router plus two workloads, all reachable' {

        BeforeEach {
            Mock Read-VmProvisionerConfig {
                ,@(
                    [PSCustomObject]@{ vmName = 'router-prod' },
                    [PSCustomObject]@{ vmName = 'wl-a' },
                    [PSCustomObject]@{ vmName = 'wl-b' }
                )
            }
            Mock Invoke-VmFleetPowerOn {
                [PSCustomObject]@{
                    Transitions = @(
                        [PSCustomObject]@{ VmName='router-prod'; EntryState='Off'; Action='Started' },
                        [PSCustomObject]@{ VmName='wl-a';        EntryState='Off'; Action='Started' },
                        [PSCustomObject]@{ VmName='wl-b';        EntryState='Off'; Action='Started' }
                    )
                    Failed = @()
                }
            }
            Mock Group-VmsByEnvironment {
                [PSCustomObject]@{
                    Name        = 'prod'
                    RouterVms   = @([PSCustomObject]@{ vmName = 'router-prod' })
                    WorkloadVms = @(
                        [PSCustomObject]@{ vmName = 'wl-a' },
                        [PSCustomObject]@{ vmName = 'wl-b' }
                    )
                }
            }
            Invoke-EnsureVmsReady
        }

        It 'powers the fleet on exactly once with the parsed VM defs' {
            Should -Invoke Invoke-VmFleetPowerOn -Times 1 -Exactly -ParameterFilter {
                @($VmDefs).Count -eq 3
            }
        }

        It 'waits the router before either workload' {
            $order = Get-WaitOrder
            $order.Count    | Should -Be 3
            $order[0]       | Should -Be 'router-prod'
        }

        It 'probes the router directly with no jump host' {
            Should -Invoke Wait-VmSshAccessible -Times 1 -Exactly -ParameterFilter {
                $Vm.vmName -eq 'router-prod' -and $null -eq $RouterVm
            }
        }

        It 'probes each workload through the router as its jump host' {
            Should -Invoke Wait-VmSshAccessible -Times 1 -Exactly -ParameterFilter {
                $Vm.vmName -eq 'wl-a' -and $RouterVm.vmName -eq 'router-prod'
            }
            Should -Invoke Wait-VmSshAccessible -Times 1 -Exactly -ParameterFilter {
                $Vm.vmName -eq 'wl-b' -and $RouterVm.vmName -eq 'router-prod'
            }
        }

        It 'emits the all-ready aggregate line' {
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                $Object -match 'Ready: 3' -and
                $Object -match 'Unreachable: 0' -and
                $Object -match 'Power-on failed: 0'
            }
        }

        It 'exits with code 0' {
            $script:exitCode | Should -Be 0
        }
    }

    Context 'router unreachable - workloads short-circuited' {

        BeforeEach {
            Mock Group-VmsByEnvironment {
                [PSCustomObject]@{
                    Name        = 'prod'
                    RouterVms   = @([PSCustomObject]@{ vmName = 'router-prod' })
                    WorkloadVms = @(
                        [PSCustomObject]@{ vmName = 'wl-a' },
                        [PSCustomObject]@{ vmName = 'wl-b' }
                    )
                }
            }
            Mock Wait-VmSshAccessible {
                [PSCustomObject]@{ Reachable = ($Vm.vmName -ne 'router-prod') }
            }
            Invoke-EnsureVmsReady
        }

        It 'never attempts a workload readiness wait for that env' {
            Should -Invoke Wait-VmSshAccessible -Times 0 -Exactly -ParameterFilter {
                $Vm.vmName -eq 'wl-a'
            }
            Should -Invoke Wait-VmSshAccessible -Times 0 -Exactly -ParameterFilter {
                $Vm.vmName -eq 'wl-b'
            }
        }

        It 'reports the workloads as router-not-ready' {
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                $Object -eq 'wl-a: Unreachable (router not ready)'
            }
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                $Object -eq 'wl-b: Unreachable (router not ready)'
            }
        }

        It 'exits with code 1' {
            $script:exitCode | Should -Be 1
        }
    }

    Context 'router fails power-on - no readiness calls for its env' {

        BeforeEach {
            Mock Invoke-VmFleetPowerOn {
                [PSCustomObject]@{
                    Transitions = @()
                    Failed      = @([PSCustomObject]@{ VmName='router-prod'; Reason='boom' })
                }
            }
            Mock Group-VmsByEnvironment {
                [PSCustomObject]@{
                    Name        = 'prod'
                    RouterVms   = @([PSCustomObject]@{ vmName = 'router-prod' })
                    WorkloadVms = @([PSCustomObject]@{ vmName = 'wl-a' })
                }
            }
            Invoke-EnsureVmsReady
        }

        It 'makes no Wait-VmSshAccessible call at all' {
            Should -Invoke Wait-VmSshAccessible -Times 0 -Exactly
        }

        It 'reports the router as power-on failed and the workload as router-not-ready' {
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                $Object -eq 'router-prod: Power-on failed'
            }
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                $Object -eq 'wl-a: Unreachable (router not ready)'
            }
        }

        It 'exits with code 1' {
            $script:exitCode | Should -Be 1
        }
    }

    Context 'one workload unreachable - router and sibling stay ready' {

        BeforeEach {
            Mock Group-VmsByEnvironment {
                [PSCustomObject]@{
                    Name        = 'prod'
                    RouterVms   = @([PSCustomObject]@{ vmName = 'router-prod' })
                    WorkloadVms = @(
                        [PSCustomObject]@{ vmName = 'wl-a' },
                        [PSCustomObject]@{ vmName = 'wl-b' }
                    )
                }
            }
            Mock Wait-VmSshAccessible {
                [PSCustomObject]@{ Reachable = ($Vm.vmName -ne 'wl-b') }
            }
            Invoke-EnsureVmsReady
        }

        It 'reports only the failing workload unreachable' {
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                $Object -eq 'wl-b: Unreachable'
            }
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                $Object -eq 'wl-a: Ready'
            }
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                $Object -eq 'router-prod: Ready'
            }
        }

        It 'aggregate reports two ready, one unreachable' {
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                $Object -match 'Ready: 2' -and
                $Object -match 'Unreachable: 1' -and
                $Object -match 'Power-on failed: 0'
            }
        }

        It 'exits with code 1' {
            $script:exitCode | Should -Be 1
        }
    }

    Context 'a workload fails power-on - siblings still processed' {

        BeforeEach {
            Mock Invoke-VmFleetPowerOn {
                [PSCustomObject]@{
                    Transitions = @(
                        [PSCustomObject]@{ VmName='router-prod'; EntryState='Off'; Action='Started' },
                        [PSCustomObject]@{ VmName='wl-b';        EntryState='Off'; Action='Started' }
                    )
                    Failed = @([PSCustomObject]@{ VmName='wl-a'; Reason='boom' })
                }
            }
            Mock Group-VmsByEnvironment {
                [PSCustomObject]@{
                    Name        = 'prod'
                    RouterVms   = @([PSCustomObject]@{ vmName = 'router-prod' })
                    WorkloadVms = @(
                        [PSCustomObject]@{ vmName = 'wl-a' },
                        [PSCustomObject]@{ vmName = 'wl-b' }
                    )
                }
            }
            Invoke-EnsureVmsReady
        }

        It 'excludes the failed workload from the readiness wait' {
            Should -Invoke Wait-VmSshAccessible -Times 0 -Exactly -ParameterFilter {
                $Vm.vmName -eq 'wl-a'
            }
        }

        It 'still waits the healthy sibling' {
            Should -Invoke Wait-VmSshAccessible -Times 1 -Exactly -ParameterFilter {
                $Vm.vmName -eq 'wl-b'
            }
        }

        It 'reports the failed workload as power-on failed' {
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                $Object -eq 'wl-a: Power-on failed'
            }
        }

        It 'exits with code 1' {
            $script:exitCode | Should -Be 1
        }
    }

    Context 'multiple environments - a dead router in one does not block another' {

        BeforeEach {
            Mock Group-VmsByEnvironment {
                @(
                    [PSCustomObject]@{
                        Name        = 'env-a'
                        RouterVms   = @([PSCustomObject]@{ vmName = 'router-a' })
                        WorkloadVms = @([PSCustomObject]@{ vmName = 'wl-a' })
                    },
                    [PSCustomObject]@{
                        Name        = 'env-b'
                        RouterVms   = @([PSCustomObject]@{ vmName = 'router-b' })
                        WorkloadVms = @([PSCustomObject]@{ vmName = 'wl-b' })
                    }
                )
            }
            Mock Wait-VmSshAccessible {
                [PSCustomObject]@{ Reachable = ($Vm.vmName -ne 'router-a') }
            }
            Invoke-EnsureVmsReady
        }

        It 'short-circuits only the dead env workload' {
            Should -Invoke Wait-VmSshAccessible -Times 0 -Exactly -ParameterFilter {
                $Vm.vmName -eq 'wl-a'
            }
        }

        It 'still readies the healthy env router and workload' {
            Should -Invoke Wait-VmSshAccessible -Times 1 -Exactly -ParameterFilter {
                $Vm.vmName -eq 'router-b' -and $null -eq $RouterVm
            }
            Should -Invoke Wait-VmSshAccessible -Times 1 -Exactly -ParameterFilter {
                $Vm.vmName -eq 'wl-b' -and $RouterVm.vmName -eq 'router-b'
            }
        }

        It 'exits with code 1' {
            $script:exitCode | Should -Be 1
        }
    }

    Context 'standalone environment - no router, workloads probed directly' {

        BeforeEach {
            Mock Group-VmsByEnvironment {
                [PSCustomObject]@{
                    Name        = 'legacy'
                    RouterVms   = @()
                    WorkloadVms = @(
                        [PSCustomObject]@{ vmName = 'standalone-a' },
                        [PSCustomObject]@{ vmName = 'standalone-b' }
                    )
                }
            }
            Invoke-EnsureVmsReady
        }

        It 'probes each workload directly with no jump host' {
            Should -Invoke Wait-VmSshAccessible -Times 1 -Exactly -ParameterFilter {
                $Vm.vmName -eq 'standalone-a' -and $null -eq $RouterVm
            }
            Should -Invoke Wait-VmSshAccessible -Times 1 -Exactly -ParameterFilter {
                $Vm.vmName -eq 'standalone-b' -and $null -eq $RouterVm
            }
        }

        It 'exits with code 0' {
            $script:exitCode | Should -Be 0
        }
    }

    Context 'idempotent re-run - already-running and reachable fleet' {

        BeforeEach {
            Mock Invoke-VmFleetPowerOn {
                [PSCustomObject]@{
                    Transitions = @(
                        [PSCustomObject]@{ VmName='router-prod'; EntryState='Running'; Action='AlreadyRunning' },
                        [PSCustomObject]@{ VmName='wl-a';        EntryState='Running'; Action='AlreadyRunning' }
                    )
                    Failed = @()
                }
            }
            Mock Group-VmsByEnvironment {
                [PSCustomObject]@{
                    Name        = 'prod'
                    RouterVms   = @([PSCustomObject]@{ vmName = 'router-prod' })
                    WorkloadVms = @([PSCustomObject]@{ vmName = 'wl-a' })
                }
            }
            Invoke-EnsureVmsReady
        }

        It 'reports every VM ready' {
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                $Object -match 'Ready: 2' -and
                $Object -match 'Unreachable: 0' -and
                $Object -match 'Power-on failed: 0'
            }
        }

        It 'exits with code 0' {
            $script:exitCode | Should -Be 0
        }
    }

    Context 'SecretSuffix is forwarded to Read-VmProvisionerConfig' {

        It 'passes the script-level -SecretSuffix through to the helper' {
            Invoke-EnsureVmsReady
            Should -Invoke Read-VmProvisionerConfig -Times 1 -Exactly `
                -ParameterFilter { $SecretSuffix -eq $script:TestSuffix }
        }
    }

    Context 'Read-VmProvisionerConfig throws - script propagates' {

        BeforeEach {
            Mock Read-VmProvisionerConfig {
                throw "Vault 'VmProvisioner' not found. Run setup-secrets.ps1 first."
            }
        }

        It 'propagates the helper exception without powering anything on' {
            { Invoke-EnsureVmsReady } | Should -Throw `
                "Vault 'VmProvisioner' not found. Run setup-secrets.ps1 first."
            Should -Invoke Invoke-VmFleetPowerOn -Times 0 -Exactly
        }
    }
}
