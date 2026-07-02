<#
.SYNOPSIS
    Behavioural unit tests for start-vms.ps1.

.DESCRIPTION
    start-vms.ps1 is a thin orchestrator: read config, power the fleet on
    via Invoke-VmFleetPowerOn, then format the result and surface an exit
    code. Its dependencies (Read-VmProvisionerConfig and the extracted
    Invoke-VmFleetPowerOn power-on loop) have their own suites and are
    mocked here so this file pins only the orchestration logic that lives
    in start-vms.ps1 itself:

      - Invoke-VmFleetPowerOn called exactly once with the parsed VM defs;
      - one per-VM transition line printed per returned transition;
      - failures surfaced on their own red line + folded into the
        aggregate line and exit code;
      - empty Failed bucket -> exit 0; non-empty -> exit 1;
      - the aggregate bucket math survives single-match scalar unrolling;
      - no SSH / file-server cmdlets invoked (the script must not touch
        the post-provisioning surface).

    The per-VM Start-VmIfStopped loop belongs to Invoke-VmFleetPowerOn;
    its coverage lives in
    Tests/common/power/Invoke-VmFleetPowerOn.Tests.ps1.

    The script cannot be dot-sourced directly because its top-level body
    runs the orchestration as a side effect. The pragmatic harness writes
    a shimmed copy to a temp dir where:

      - Install-ModuleDependencies.ps1 is empty (so the test host does
        not pay the bootstrap cost),
      - common/config/*.ps1 and common/power/*.ps1 helpers are empty (the
        helper functions used by the script are stubbed in the test scope
        so Pester's Mock can attach to them),
      - the `exit (...)` line is rewritten to assign $script:exitCode and
        return, so the test process is not terminated by the script.

    The text-level rewrite is intentionally narrow (one regex against the
    `exit (...)` line) so a future contributor who changes the orchestration
    body still gets full coverage from this suite.
#>

BeforeAll {
    $script:realPath = Join-Path $PSScriptRoot '..\..\hyper-v\ubuntu\PowerShell\start-vms.ps1'

    # Build a sibling shim directory so $PSScriptRoot inside the script
    # resolves to a sandbox we control. Empty stub files satisfy every
    # dot-source; the real behaviour is provided by Pester mocks against
    # the function names defined in this BeforeAll.
    $script:shimDir = Join-Path ([IO.Path]::GetTempPath()) `
        ("start-vms-test-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $script:shimDir 'common\config') `
        -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $script:shimDir 'common\power') `
        -Force | Out-Null

    foreach ($rel in @(
        'common\config\ConvertFrom-VmConfigJson.ps1',
        'common\config\Get-SanitizedVmDisplay.ps1',
        'common\config\Read-VmProvisionerConfig.ps1',
        'common\power\Invoke-VmFleetPowerOn.ps1',
        'Install-ModuleDependencies.ps1'
    )) {
        Set-Content -LiteralPath (Join-Path $script:shimDir $rel) -Value '' `
            -Encoding UTF8
    }

    # Rewrite the terminal `exit (...)` to a captured assignment so the
    # test process is not killed when the script reaches its bottom line.
    # `-replace` uses .NET regex substitution, where `$name` is a named
    # backreference - so the literal `$` characters in the replacement are
    # escaped as `$$` to produce a real `$` in the output. The chosen exit
    # code is emitted to the pipeline (instead of `exit`-ing the process)
    # so the test can capture it from `& $shimPath`.
    $raw  = Get-Content -Raw -LiteralPath $script:realPath
    $shim = $raw -replace `
        '(?m)^exit\s+\(.*\)\s*$', `
        '($$failedCount -gt 0 ? 1 : 0)'
    Set-Content -LiteralPath (Join-Path $script:shimDir 'start-vms.ps1') `
        -Value $shim -Encoding UTF8
    $script:shimPath = Join-Path $script:shimDir 'start-vms.ps1'

    # Stub functions that the script calls. Pester's Mock attaches to
    # these by name; the real implementations are covered by:
    #   - Tests/common/config/Read-VmProvisionerConfig.Tests.ps1
    #   - Tests/common/power/Invoke-VmFleetPowerOn.Tests.ps1
    # SecretSuffix / VmDefs declared on the stubs so Pester's
    # ParameterFilter can bind them when asserting forwarded values.
    function Read-VmProvisionerConfig { param([string] $SecretSuffix) }
    function Invoke-VmFleetPowerOn    { param([object[]] $VmDefs) }

    # SSH / file-server cmdlets the no-side-effect contract forbids the
    # script from touching. Stubbed so the test can assert -Not -Invoke
    # against each.
    function Invoke-WithVmFileServer { }
    function New-VmSshClient        { }
    function Invoke-SshClientCommand { }
    function Wait-VmSshReady        { }

    # Suffix passed to the shim on every invocation. The script's
    # mandatory -SecretSuffix is forwarded to Read-VmProvisionerConfig,
    # which is mocked here, so the literal value does not matter to the
    # behavioural assertions - it just needs to satisfy the param block.
    $script:TestSuffix = 'Test'

    # Builds an Invoke-VmFleetPowerOn-shaped result object so each Context
    # can drive the formatting + exit-code contract from a fixture instead
    # of the real power-on loop.
    function New-PowerOnResult {
        param(
            [object[]] $Transitions = @(),
            [object[]] $Failed      = @()
        )
        [PSCustomObject]@{
            Transitions = @($Transitions)
            Failed      = @($Failed)
        }
    }

    function Invoke-StartVms {
        # The shimmed script emits the chosen exit code to the pipeline
        # (regex-replaced from the original `exit (...)` line). Capture
        # it so the test can inspect the code without the host process
        # being terminated.
        $script:exitCode = & $script:shimPath -SecretSuffix $script:TestSuffix
    }
}

AfterAll {
    if ($script:shimDir -and (Test-Path -LiteralPath $script:shimDir)) {
        Remove-Item -LiteralPath $script:shimDir -Recurse -Force `
            -ErrorAction SilentlyContinue
    }
}

Describe 'start-vms.ps1 - orchestration' {

    BeforeEach {
        # Default mocks; each Context overrides what it cares about.
        Mock Read-VmProvisionerConfig { }
        Mock Invoke-VmFleetPowerOn { New-PowerOnResult }
        Mock Write-Host { }
    }

    Context 'happy path - three transitions, one of each kind' {

        BeforeEach {
            Mock Read-VmProvisionerConfig {
                ,@(
                    [PSCustomObject]@{ vmName = 'vm-a' },
                    [PSCustomObject]@{ vmName = 'vm-b' },
                    [PSCustomObject]@{ vmName = 'vm-c' }
                )
            }
            Mock Invoke-VmFleetPowerOn {
                New-PowerOnResult -Transitions @(
                    [PSCustomObject]@{ VmName='vm-a'; EntryState='Off';     Action='Started'        },
                    [PSCustomObject]@{ VmName='vm-b'; EntryState='Saved';   Action='Resumed'        },
                    [PSCustomObject]@{ VmName='vm-c'; EntryState='Running'; Action='AlreadyRunning' }
                )
            }
            Invoke-StartVms
        }

        It 'calls Invoke-VmFleetPowerOn exactly once with the parsed VM defs' {
            Should -Invoke Invoke-VmFleetPowerOn -Times 1 -Exactly -ParameterFilter {
                @($VmDefs).Count -eq 3 -and
                $VmDefs[0].vmName -eq 'vm-a' -and
                $VmDefs[2].vmName -eq 'vm-c'
            }
        }

        It 'prints one transition line per returned transition' {
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                $Object -eq 'vm-a: Off -> Started'
            }
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                $Object -eq 'vm-b: Saved -> Resumed'
            }
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                $Object -eq 'vm-c: Running -> AlreadyRunning'
            }
        }

        It 'emits the aggregate line with the correct bucket counts' {
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                $Object -match 'Started: 1' -and
                $Object -match 'Resumed: 1' -and
                $Object -match 'Already running: 1' -and
                $Object -match 'Failed: 0'
            }
        }

        It 'exits with code 0' {
            $script:exitCode | Should -Be 0
        }
    }

    Context 'single failure does not strand the rest of the list' {

        BeforeEach {
            Mock Read-VmProvisionerConfig {
                ,@(
                    [PSCustomObject]@{ vmName = 'vm-a' },
                    [PSCustomObject]@{ vmName = 'vm-b' },
                    [PSCustomObject]@{ vmName = 'vm-c' },
                    [PSCustomObject]@{ vmName = 'vm-d' }
                )
            }
            Mock Invoke-VmFleetPowerOn {
                New-PowerOnResult `
                    -Transitions @(
                        [PSCustomObject]@{ VmName='vm-a'; EntryState='Off'; Action='Started' },
                        [PSCustomObject]@{ VmName='vm-c'; EntryState='Off'; Action='Started' },
                        [PSCustomObject]@{ VmName='vm-d'; EntryState='Off'; Action='Started' }
                    ) `
                    -Failed @(
                        [PSCustomObject]@{
                            VmName = 'vm-b'
                            Reason = "VM 'vm-b' is in transient/unsupported state 'Paused'; refusing to call Start-VM."
                        }
                    )
            }
            Invoke-StartVms
        }

        It 'surfaces the failed VM on its own line with the upstream reason' {
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                $Object -match '^vm-b: FAILED - ' -and
                $Object -match "transient/unsupported state 'Paused'"
            }
        }

        It 'aggregate line reports Failed: 1 and Started: 3' {
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                $Object -match 'Started: 3' -and
                $Object -match 'Failed: 1'
            }
        }

        It 'exits with code 1' {
            $script:exitCode | Should -Be 1
        }
    }

    Context 'multiple failures - all surface, exit 1' {

        BeforeEach {
            Mock Invoke-VmFleetPowerOn {
                New-PowerOnResult `
                    -Transitions @(
                        [PSCustomObject]@{ VmName='vm-b'; EntryState='Off'; Action='Started' }
                    ) `
                    -Failed @(
                        [PSCustomObject]@{ VmName='vm-a'; Reason='boom-vm-a' },
                        [PSCustomObject]@{ VmName='vm-c'; Reason='boom-vm-c' }
                    )
            }
            Invoke-StartVms
        }

        It 'prints every failure on its own line' {
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                $Object -match '^vm-a: FAILED - boom-vm-a$'
            }
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                $Object -match '^vm-c: FAILED - boom-vm-c$'
            }
        }

        It 'aggregate line reports Failed: 2' {
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                $Object -match 'Failed: 2'
            }
        }

        It 'exits with code 1' {
            $script:exitCode | Should -Be 1
        }
    }

    Context 'every VM fails' {

        BeforeEach {
            Mock Invoke-VmFleetPowerOn {
                New-PowerOnResult -Failed @(
                    [PSCustomObject]@{ VmName='vm-a'; Reason='boom-vm-a' },
                    [PSCustomObject]@{ VmName='vm-b'; Reason='boom-vm-b' }
                )
            }
            Invoke-StartVms
        }

        It 'aggregate line zeroes the success buckets and reports Failed: N' {
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                $Object -match 'Started: 0' -and
                $Object -match 'Resumed: 0' -and
                $Object -match 'Already running: 0' -and
                $Object -match 'Failed: 2'
            }
        }

        It 'exits with code 1' {
            $script:exitCode | Should -Be 1
        }
    }

    Context 'single-transition result - aggregate-line bucket math survives unrolling' {

        # If a `@(...)` wrapper is dropped from a Where-Object pipeline in
        # start-vms.ps1, the bucket count for a single match silently
        # becomes the field value of the unwrapped object - the regex on
        # the literal output pins the *string*, not an indexed result.
        BeforeEach {
            Mock Invoke-VmFleetPowerOn {
                New-PowerOnResult -Transitions @(
                    [PSCustomObject]@{ VmName='vm-only'; EntryState='Off'; Action='Started' }
                )
            }
            Invoke-StartVms
        }

        It 'reports Started: 1, every other bucket 0' {
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                $Object -match 'Started: 1' -and
                $Object -match 'Resumed: 0' -and
                $Object -match 'Already running: 0' -and
                $Object -match 'Failed: 0'
            }
        }

        It 'exits with code 0' {
            $script:exitCode | Should -Be 0
        }
    }

    Context 'SecretSuffix is forwarded to Read-VmProvisionerConfig' {

        # Pins the wiring added in commit 0874c5d. A regression that
        # drops the -SecretSuffix forward (or hard-codes a default
        # value) would silently route every invocation at the same
        # vault entry, defeating the per-lifecycle isolation that
        # justifies the mandatory param.

        It 'passes the script-level -SecretSuffix through to the helper' {
            Mock Read-VmProvisionerConfig { ,@() }
            Invoke-StartVms
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
            { Invoke-StartVms } | Should -Throw `
                "Vault 'VmProvisioner' not found. Run setup-secrets.ps1 first."
            Should -Invoke Invoke-VmFleetPowerOn -Times 0 -Exactly
        }
    }

    Context 'no-side-effect contract - SSH / file-server cmdlets stay quiet' {

        # Pinpoints a future contributor accidentally importing the SSH
        # / file-server orchestration into this script. Power-on is the
        # only intended side effect; everything in this list belongs to
        # provision.ps1's post-provisioning surface, not start-vms.ps1.
        BeforeEach {
            Mock Read-VmProvisionerConfig {
                ,@([PSCustomObject]@{ vmName = 'vm-a' })
            }
            Mock Invoke-VmFleetPowerOn {
                New-PowerOnResult -Transitions @(
                    [PSCustomObject]@{ VmName='vm-a'; EntryState='Off'; Action='Started' }
                )
            }
            Mock Invoke-WithVmFileServer { }
            Mock New-VmSshClient        { }
            Mock Invoke-SshClientCommand { }
            Mock Wait-VmSshReady        { }
            Invoke-StartVms
        }

        It 'does not invoke Invoke-WithVmFileServer' {
            Should -Invoke Invoke-WithVmFileServer -Times 0 -Exactly
        }
        It 'does not invoke New-VmSshClient' {
            Should -Invoke New-VmSshClient -Times 0 -Exactly
        }
        It 'does not invoke Invoke-SshClientCommand' {
            Should -Invoke Invoke-SshClientCommand -Times 0 -Exactly
        }
        It 'does not invoke Wait-VmSshReady' {
            Should -Invoke Wait-VmSshReady -Times 0 -Exactly
        }
    }
}
