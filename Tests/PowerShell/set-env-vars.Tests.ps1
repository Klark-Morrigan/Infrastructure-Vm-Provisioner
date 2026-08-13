<#
.SYNOPSIS
    Behavioural unit tests for set-env-vars.ps1.

.DESCRIPTION
    set-env-vars.ps1 is a thin orchestrator: read config, select the VMs that
    declare `envVars`, stamp each workload's jump host, then call the shared
    Set-EnvironmentVariables step once per VM and aggregate an exit code. The
    transport, the connect helper and the config reader all have their own
    suites and are mocked here, so this file pins only what lives in the
    script:

      - selection is by FIELD PRESENCE, so an `entries: []` retraction is
        still visited while a VM with no envVars at all is skipped;
      - -VmName narrows the run, and an unmatched name is a loud error
        rather than a silent no-op;
      - workloads reach the transport carrying their environment's router as
        _RouterVm, and routers carry none;
      - one unreachable VM does not strand the rest;
      - the SSH session is disposed on the failure path as well as the happy
        one;
      - exit 0 only when every VM succeeded, exit 1 otherwise.

    Harness: the script cannot be dot-sourced directly because its top-level
    body runs the orchestration as a side effect. As in ensure-vms-ready.
    Tests.ps1 a shimmed copy is written to a temp dir where every dot-source
    resolves to an empty stub file, and each terminal `exit <n>` is rewritten
    to `return <n>` - which both emits the code to the pipeline and preserves
    the early-exit control flow the "nothing declares envVars" branch needs.
#>

# PSAvoidGlobalVars is suppressed file-wide: the disposal counter and the
# Write-Host transcript are read and written while `& $shimPath` is on the
# call stack, where $script: resolves to the shimmed script's scope rather
# than this file's. Global scope is the only tracker both sides can see.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'Pester v5 cross-scope mock-call trackers')]
param()

BeforeAll {
    $script:realPath = Join-Path $PSScriptRoot '..\..\hyper-v\ubuntu\PowerShell\set-env-vars.ps1'

    $script:shimDir = Join-Path ([IO.Path]::GetTempPath()) `
        ("set-env-vars-test-" + [Guid]::NewGuid().ToString('N'))
    foreach ($sub in @('common\config', 'common\network', 'up\post')) {
        New-Item -ItemType Directory -Path (Join-Path $script:shimDir $sub) `
            -Force | Out-Null
    }
    foreach ($rel in @(
        'common\config\Group-VmsByEnvironment.ps1',
        'common\config\Read-VmProvisionerConfig.ps1',
        'common\network\Resolve-ExistingRouterIp.ps1',
        'up\post\Set-EnvironmentVariables.ps1',
        'Install-ModuleDependencies.ps1'
    )) {
        Set-Content -LiteralPath (Join-Path $script:shimDir $rel) -Value '' `
            -Encoding UTF8
    }

    # `return <n>` rather than a bare expression: the script exits early when
    # nothing declares envVars, and a bare value there would fall through into
    # the apply loop and connect to VMs the real script never would.
    #
    # The leading-whitespace group is load-bearing. Two of the three exits sit
    # inside an `if` block, and a column-0-anchored pattern leaves those as
    # real `exit` calls - which terminate the shim silently and hand the test
    # $null instead of the code, so the exit-code assertions fail while the
    # script under test is perfectly correct.
    $raw  = Get-Content -Raw -LiteralPath $script:realPath
    $shim = $raw -replace '(?m)^(\s*)exit\s+(\d+)\s*$', '$1return $2'
    Set-Content -LiteralPath (Join-Path $script:shimDir 'set-env-vars.ps1') `
        -Value $shim -Encoding UTF8
    $script:shimPath = Join-Path $script:shimDir 'set-env-vars.ps1'

    # Stub functions the script calls. Param blocks are declared so
    # ParameterFilter can bind the forwarded values by name.
    function Read-VmProvisionerConfig { param([string] $SecretSuffix) }
    function Group-VmsByEnvironment   { param([object[]] $VmDefs) }
    function Resolve-ExistingRouterIp { param([object] $RouterVm) }
    function Set-EnvironmentVariables { param([object] $SshClient, [object] $Vm) }
    function New-VmSshClientWithJump  { param([object] $Vm, [timespan] $Timeout) }

    # Fixture builders. Inlined into each mock body at the call sites below
    # rather than shared through a $script: variable: mock bodies execute
    # while `& $shimPath` is on the call stack, where $script: resolves to the
    # shimmed script's scope rather than this file's.
    function New-TestVm {
        param([string] $Name, [object] $EnvVars, [switch] $Router)

        $vm = [PSCustomObject]@{ vmName = $Name; ipAddress = '10.0.0.1' }
        if ($Router) {
            Add-Member -InputObject $vm -MemberType NoteProperty `
                       -Name 'kind' -Value 'router' -Force
        }
        if ($null -ne $EnvVars) {
            Add-Member -InputObject $vm -MemberType NoteProperty `
                       -Name 'envVars' -Value $EnvVars -Force
        }
        return $vm
    }

    function New-TestEnvVars {
        param([object[]] $Entries)
        return [PSCustomObject]@{ blockName = 'ci-jars'; entries = $Entries }
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:shimDir -Recurse -Force `
        -ErrorAction SilentlyContinue
}

Describe 'set-env-vars.ps1' {

    BeforeEach {
        Mock Write-Host {}
        Mock Resolve-ExistingRouterIp {}
        Mock Set-EnvironmentVariables {}

        # A session double that records disposal, so the finally block can be
        # asserted without reaching a real SSH client.
        $global:_SetEnvVars_Disposed = 0
        Mock New-VmSshClientWithJump {
            $session = [PSCustomObject]@{ Client = 'ssh-client-double' }
            Add-Member -InputObject $session -MemberType ScriptMethod `
                       -Name 'Dispose' `
                       -Value { $global:_SetEnvVars_Disposed++ } -Force
            return $session
        }

        # Default fleet: one router plus two workloads, only one of which
        # declares envVars. Grouping mirrors what the real helper returns.
        Mock Read-VmProvisionerConfig {
            @(
                (New-TestVm -Name 'router-01' -Router),
                (New-TestVm -Name 'vm-with' -EnvVars (New-TestEnvVars -Entries @(
                    [PSCustomObject]@{ name = 'FOO'; value = '/opt/foo' }))),
                (New-TestVm -Name 'vm-without')
            )
        }
        Mock Group-VmsByEnvironment {
            @([PSCustomObject]@{
                RouterVms   = @($VmDefs | Where-Object {
                    $_.PSObject.Properties['kind'] })
                WorkloadVms = @($VmDefs | Where-Object {
                    -not $_.PSObject.Properties['kind'] })
            })
        }
    }

    Context 'target selection' {

        It 'applies only to VMs that declare envVars' {
            & $script:shimPath -SecretSuffix 'Test' | Out-Null

            Should -Invoke Set-EnvironmentVariables -Exactly -Times 1
            Should -Invoke Set-EnvironmentVariables -Exactly -Times 1 `
                -ParameterFilter { $Vm.vmName -eq 'vm-with' }
        }

        It 'visits a VM whose entries list is empty' {
            # `entries: []` is the operator's "remove the managed block"
            # intent. Gating on entries.Count instead of field presence would
            # make a retraction silently do nothing - the failure mode that
            # leaves a stale variable on the host forever.
            Mock Read-VmProvisionerConfig {
                @( (New-TestVm -Name 'vm-retract' `
                        -EnvVars (New-TestEnvVars -Entries @())) )
            }

            & $script:shimPath -SecretSuffix 'Test' | Out-Null

            Should -Invoke Set-EnvironmentVariables -Exactly -Times 1 `
                -ParameterFilter { $Vm.vmName -eq 'vm-retract' }
        }

        It 'connects to nothing when no VM declares envVars' {
            Mock Read-VmProvisionerConfig { @( (New-TestVm -Name 'plain') ) }

            $code = & $script:shimPath -SecretSuffix 'Test'

            $code | Should -Be 0
            Should -Invoke New-VmSshClientWithJump -Exactly -Times 0
        }

        It 'narrows the run to the named VM' {
            Mock Read-VmProvisionerConfig {
                @(
                    (New-TestVm -Name 'vm-a' -EnvVars (New-TestEnvVars -Entries @())),
                    (New-TestVm -Name 'vm-b' -EnvVars (New-TestEnvVars -Entries @()))
                )
            }

            & $script:shimPath -SecretSuffix 'Test' -VmName 'vm-b' | Out-Null

            Should -Invoke Set-EnvironmentVariables -Exactly -Times 1 `
                -ParameterFilter { $Vm.vmName -eq 'vm-b' }
        }

        It 'names the requested VMs when they exist but declare no envVars' {
            # The VM is in the config, so the unmatched-name check passes and
            # the run is a legitimate no-op - but reporting it as "no VM
            # declares envVars" would describe the fleet rather than the
            # request, and hide the config typo the operator came to find.
            Mock Read-VmProvisionerConfig { @( (New-TestVm -Name 'plain') ) }
            # $global:, not $script: - see the file header for why.
            $global:_SetEnvVars_Said = [System.Collections.Generic.List[string]]::new()
            Mock Write-Host { $global:_SetEnvVars_Said.Add([string]$Object) }

            & $script:shimPath -SecretSuffix 'Test' -VmName 'plain' | Out-Null

            ($global:_SetEnvVars_Said -join ' ') |
                Should -BeLike '*None of plain declares envVars*'
            Should -Invoke New-VmSshClientWithJump -Exactly -Times 0
        }

        It 'throws on a VM name that is not in the config' {
            # A targeted run that silently matched nothing would report
            # success for work it never did - the same class of failure the
            # Ansible play's unknown-sub-field rule exists to prevent.
            { & $script:shimPath -SecretSuffix 'Test' -VmName 'typo-vm' } |
                Should -Throw '*typo-vm*'
        }
    }

    Context 'jump-host stamping' {

        It 'hands a workload its environment router' {
            & $script:shimPath -SecretSuffix 'Test' | Out-Null

            Should -Invoke New-VmSshClientWithJump -Exactly -Times 1 `
                -ParameterFilter {
                    $Vm.vmName -eq 'vm-with' -and
                    $Vm._RouterVm.vmName -eq 'router-01'
                }
        }

        It 'leaves a router without a jump host of its own' {
            # A router sits on a switch the host routes to directly; giving it
            # a _RouterVm would tunnel it through itself.
            Mock Read-VmProvisionerConfig {
                @( (New-TestVm -Name 'router-01' -Router `
                        -EnvVars (New-TestEnvVars -Entries @())) )
            }

            & $script:shimPath -SecretSuffix 'Test' | Out-Null

            Should -Invoke New-VmSshClientWithJump -Exactly -Times 1 `
                -ParameterFilter {
                    -not $Vm.PSObject.Properties['_RouterVm']
                }
        }

        It 'resolves the router IP before using it as a jump host' {
            # A rebuilt router may not carry its address statically; without
            # this the tunnel dials an empty host.
            & $script:shimPath -SecretSuffix 'Test' | Out-Null

            Should -Invoke Resolve-ExistingRouterIp -Exactly -Times 1 `
                -ParameterFilter { $RouterVm.vmName -eq 'router-01' }
        }
    }

    Context 'failure isolation' {

        It 'continues to the next VM after one fails' {
            Mock Read-VmProvisionerConfig {
                @(
                    (New-TestVm -Name 'vm-bad'  -EnvVars (New-TestEnvVars -Entries @())),
                    (New-TestVm -Name 'vm-good' -EnvVars (New-TestEnvVars -Entries @()))
                )
            }
            Mock Set-EnvironmentVariables {
                if ($Vm.vmName -eq 'vm-bad') { throw 'ssh channel closed' }
            }

            $code = & $script:shimPath -SecretSuffix 'Test'

            $code | Should -Be 1
            Should -Invoke Set-EnvironmentVariables -Exactly -Times 1 `
                -ParameterFilter { $Vm.vmName -eq 'vm-good' }
        }

        It 'disposes the session when the write throws' {
            # The session owns the jump tunnel as well as the client, so a
            # leaked one holds a forwarded port open for the rest of the run.
            Mock Read-VmProvisionerConfig {
                @( (New-TestVm -Name 'vm-bad' -EnvVars (New-TestEnvVars -Entries @())) )
            }
            Mock Set-EnvironmentVariables { throw 'ssh channel closed' }

            & $script:shimPath -SecretSuffix 'Test' | Out-Null

            $global:_SetEnvVars_Disposed | Should -Be 1
        }

        It 'exits 0 when every VM succeeded' {
            $code = & $script:shimPath -SecretSuffix 'Test'

            $code | Should -Be 0
        }
    }
}
