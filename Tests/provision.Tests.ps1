<#
.SYNOPSIS
    Structural wiring checks for provision.ps1.

.DESCRIPTION
    provision.ps1 has top-level side effects (vault read, module imports) so
    it cannot be dot-sourced safely from a test. As a pragmatic compromise
    these tests parse the file via AST and assert:
      - Invoke-JdkAcquisition (host-side prefetch) is wired between disk
        acquisition and seed-ISO generation, guarded by 'javaDevKit'.
      - Invoke-JdkInstall (on-VM install over the host file server) is
        wired after Invoke-VmCreation, guarded by 'javaDevKit'.

    Behavioural coverage of the JDK functions themselves lives in
    Tests/up/jdk/Invoke-JdkAcquisition.Tests.ps1 and
    Tests/up/jdk/Invoke-JdkInstall.Tests.ps1.
#>

BeforeAll {
    $script:provisionPath = Join-Path $PSScriptRoot `
        '..\hyper-v\ubuntu\provision.ps1'

    $tokens    = $null
    $parseErrs = $null
    $script:ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:provisionPath, [ref] $tokens, [ref] $parseErrs)

    if ($parseErrs.Count -gt 0) {
        throw "provision.ps1 has parse errors: $($parseErrs -join '; ')"
    }

    # Pull every command invocation in the file once so each test can filter
    # cheaply by command name.
    $script:commands = $script:ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
    }, $true)

    # Returns the name of the variable that the foreach enclosing the first
    # CommandAst for $CommandName iterates over, e.g. 'newVms' or
    # 'vmsToProcess'. Used by the destructive-vs-additive loop-target
    # assertions below.
    #
    # AST shape: foreach ($vm in $newVms) { ... Invoke-Foo ... }
    #   ForEachStatementAst.Variable  -> $vm   (per-iteration variable)
    #   ForEachStatementAst.Condition -> $newVms (iterated expression)
    function Get-LoopVarFor {
        param([string] $CommandName)
        $call = $script:commands |
            Where-Object { $_.GetCommandName() -eq $CommandName } |
            Select-Object -First 1
        if ($null -eq $call) {
            throw "No CommandAst found for '$CommandName' in provision.ps1."
        }
        $node = $call.Parent
        while ($null -ne $node -and
               -not ($node -is [System.Management.Automation.Language.ForEachStatementAst])) {
            $node = $node.Parent
        }
        if ($null -eq $node) {
            throw "Call to '$CommandName' is not inside a foreach loop."
        }
        # ForEachStatementAst.Condition is a PipelineAst, even when the
        # iterated expression is a bare $var. Drill down through
        #   PipelineAst -> PipelineElements[0] (CommandExpressionAst)
        #     -> Expression (VariableExpressionAst)
        # and accept only that shape so the test stays precise.
        $expr = $node.Condition
        if ($expr -is [System.Management.Automation.Language.PipelineAst] -and
            $expr.PipelineElements.Count -eq 1 -and
            $expr.PipelineElements[0] -is
                [System.Management.Automation.Language.CommandExpressionAst]) {
            $expr = $expr.PipelineElements[0].Expression
        }
        if ($expr -isnot
            [System.Management.Automation.Language.VariableExpressionAst]) {
            throw ("foreach for '$CommandName' iterates a non-variable " +
                "expression: $($node.Condition.Extent.Text)")
        }
        return $expr.VariablePath.UserPath
    }
}

Describe 'provision.ps1 - bootstrap wiring (Read-VmProvisionerConfig)' {

    # The vault read / SecretManagement bootstrap was extracted to
    # common/config/Read-VmProvisionerConfig.ps1. These tests pin the
    # delegation so a future change cannot silently reintroduce the inline
    # vault-handling code (which would split error wording across two
    # places and break the helper's test coverage).

    It 'dot-sources Read-VmProvisionerConfig.ps1' {
        $text = Get-Content -Path $script:provisionPath -Raw
        $text | Should -Match 'Read-VmProvisionerConfig\.ps1'
    }

    It 'invokes Read-VmProvisionerConfig exactly once' {
        $calls = $script:commands |
            Where-Object { $_.GetCommandName() -eq 'Read-VmProvisionerConfig' }
        @($calls).Count | Should -Be 1
    }

    It 'does not call Get-SecretVault directly (helper owns it)' {
        $calls = $script:commands |
            Where-Object { $_.GetCommandName() -eq 'Get-SecretVault' }
        @($calls).Count | Should -Be 0 `
            -Because 'vault discovery moved into Read-VmProvisionerConfig'
    }

    It 'does not call Get-Secret directly (helper owns it)' {
        $calls = $script:commands |
            Where-Object { $_.GetCommandName() -eq 'Get-Secret' }
        @($calls).Count | Should -Be 0 `
            -Because 'secret retrieval moved into Read-VmProvisionerConfig'
    }

    # The mandatory -SecretSuffix added in commit 0874c5d gives each
    # lifecycle its own VmProvisionerConfig-<Suffix> entry. A regression
    # that drops the forwarding (or substitutes a literal) would silently
    # route every invocation at the same vault key, defeating the
    # isolation. These two AST checks pin the contract end-to-end:
    # script accepts the param, and forwards the same variable through
    # to the helper.

    It 'declares -SecretSuffix as a mandatory script parameter' {
        $param = $script:ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'SecretSuffix' } |
            Select-Object -First 1
        $param | Should -Not -BeNullOrEmpty `
            -Because 'provision.ps1 must surface SecretSuffix to the operator'
        $hasMandatory = $param.Attributes | Where-Object {
            $_.TypeName.Name -eq 'Parameter' -and
            ($_.NamedArguments | Where-Object {
                $_.ArgumentName -eq 'Mandatory'
            })
        }
        $hasMandatory | Should -Not -BeNullOrEmpty `
            -Because 'SecretSuffix must be mandatory so the caller cannot fall through to a default'
    }

    It 'forwards the script-level $SecretSuffix to Read-VmProvisionerConfig' {
        $call = $script:commands |
            Where-Object { $_.GetCommandName() -eq 'Read-VmProvisionerConfig' } |
            Select-Object -First 1

        # Walk the CommandElements in pairs looking for a
        #   -SecretSuffix $SecretSuffix
        # neighbour. CommandElements[0] is the command name, elements
        # alternate between CommandParameterAst (-Name) and the value
        # expression that follows.
        $forwarded = $false
        for ($i = 1; $i -lt $call.CommandElements.Count - 1; $i++) {
            $cur  = $call.CommandElements[$i]
            $next = $call.CommandElements[$i + 1]
            if ($cur -is [System.Management.Automation.Language.CommandParameterAst] -and
                $cur.ParameterName -eq 'SecretSuffix' -and
                $next -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $next.VariablePath.UserPath -eq 'SecretSuffix') {
                $forwarded = $true
                break
            }
        }
        $forwarded | Should -BeTrue `
            -Because 'a regression that hard-codes the suffix would silently collide lifecycles'
    }
}

Describe 'provision.ps1 - acquisition wiring (Step 4)' {

    It 'dot-sources Invoke-VmAcquisitions.ps1' {
        $text = Get-Content -Path $script:provisionPath -Raw
        $text | Should -Match 'Invoke-VmAcquisitions\.ps1'
    }

    It 'dot-sources Invoke-JdkAcquisition.ps1 (consumed by Invoke-VmAcquisitions)' {
        $text = Get-Content -Path $script:provisionPath -Raw
        $text | Should -Match 'Invoke-JdkAcquisition\.ps1'
    }

    It 'dot-sources Resolve-AdoptiumRelease.ps1 before Invoke-JdkAcquisition.ps1' {
        # Resolver must be loaded first because Invoke-JdkAcquisition.ps1
        # references Resolve-AdoptiumRelease at call time.
        $text       = Get-Content -Path $script:provisionPath -Raw
        $resolverAt = $text.IndexOf('Resolve-AdoptiumRelease.ps1')
        $acqAt      = $text.IndexOf('Invoke-JdkAcquisition.ps1')

        $resolverAt | Should -BeGreaterThan -1
        $acqAt      | Should -BeGreaterThan -1
        $resolverAt | Should -BeLessThan $acqAt
    }

    It 'dot-sources the per-software acquirers before the orchestrator' {
        # Orchestrator references the acquirer functions at call time;
        # loading them after would still work, but loading them before is
        # the convention this repo follows (matches the post side).
        $text   = Get-Content -Path $script:provisionPath -Raw
        $orchAt = $text.IndexOf('Invoke-VmAcquisitions.ps1')
        $jdkAt  = $text.IndexOf('Invoke-JdkAcquisition.ps1')
        $jdkAt | Should -BeLessThan $orchAt
    }

    It 'invokes Invoke-VmAcquisitions exactly once' {
        $calls = $script:commands |
            Where-Object { $_.GetCommandName() -eq 'Invoke-VmAcquisitions' }
        @($calls).Count | Should -Be 1
    }

    It 'calls Invoke-VmAcquisitions unconditionally (no per-field guard at orchestrator)' {
        # Field guards live INSIDE Invoke-VmAcquisitions so the orchestrator
        # does not need to know which acquirers each VM enables. This test
        # asserts the call is NOT inside an if-statement. Mirrors the
        # post-provisioning wiring shape.
        $call = $script:commands |
            Where-Object { $_.GetCommandName() -eq 'Invoke-VmAcquisitions' } |
            Select-Object -First 1

        $ifAst = $call.Parent
        while ($null -ne $ifAst -and
               -not ($ifAst -is [System.Management.Automation.Language.IfStatementAst])) {
            $ifAst = $ifAst.Parent
        }

        $ifAst | Should -BeNullOrEmpty `
            -Because 'Invoke-VmAcquisitions must be called for every VM; it self-skips when no opt-in fields are set'
    }

    It 'places Invoke-VmAcquisitions after disk acquisition and before seed-ISO generation' {
        # Ordering matters: vhdPath is created by Invoke-DiskImageAcquisition,
        # and the seed-ISO generator consumes _jdkTarballPath produced by
        # the JDK acquirer dispatched inside Invoke-VmAcquisitions.
        $byName = @{}
        foreach ($cmd in $script:commands) {
            $name = $cmd.GetCommandName()
            if ($name -in 'Invoke-DiskImageAcquisition',
                          'Invoke-VmAcquisitions',
                          'Invoke-SeedIsoGeneration') {
                if (-not $byName.ContainsKey($name)) {
                    $byName[$name] = $cmd.Extent.StartOffset
                }
            }
        }

        $byName['Invoke-DiskImageAcquisition'] |
            Should -BeLessThan $byName['Invoke-VmAcquisitions']
        $byName['Invoke-VmAcquisitions'] |
            Should -BeLessThan $byName['Invoke-SeedIsoGeneration']
    }
}

Describe 'provision.ps1 - post-provisioning wiring (Step 5)' {

    It 'dot-sources Invoke-VmPostProvisioning.ps1' {
        $text = Get-Content -Path $script:provisionPath -Raw
        $text | Should -Match 'Invoke-VmPostProvisioning\.ps1'
    }

    It 'dot-sources Get-JdkProvider before the orchestrator' {
        # Get-JdkProvider composes the four JdkProvider.* operations into
        # the IToolchainProvider object Get-Providers hands the
        # reconciler. Orchestrator references step functions at call
        # time; loading them after the orchestrator would still work,
        # but loading them before is the convention this repo follows.
        # Copy-VmFiles is NOT dot-sourced - it lives in
        # Infrastructure.HyperV and is imported by Install-ModuleDependencies.ps1.
        $text   = Get-Content -Path $script:provisionPath -Raw
        $orchAt = $text.IndexOf('Invoke-VmPostProvisioning.ps1')
        $stepAt = $text.IndexOf('Get-JdkProvider.ps1')
        $stepAt | Should -BeGreaterThan -1
        $stepAt | Should -BeLessThan $orchAt
    }

    It 'does not dot-source Install-Jdk or Uninstall-Jdk scripts' {
        # Regression guard: the reconciler owns the JDK lifecycle; a
        # dot-source of these names would shadow the manifest-driven path.
        $text = Get-Content -Path $script:provisionPath -Raw
        $text | Should -Not -Match 'Install-Jdk\.ps1'
        $text | Should -Not -Match 'Uninstall-Jdk\.ps1'
    }

    It 'invokes Invoke-VmPostProvisioning exactly once' {
        $calls = $script:commands |
            Where-Object { $_.GetCommandName() -eq 'Invoke-VmPostProvisioning' }
        @($calls).Count | Should -Be 1
    }

    It 'calls Invoke-VmPostProvisioning unconditionally (no per-field guard at orchestrator)' {
        # Field guards live INSIDE Invoke-VmPostProvisioning so the
        # orchestrator does not need to know which steps each VM enables.
        # This test asserts the call is NOT inside an if-statement.
        $call = $script:commands |
            Where-Object { $_.GetCommandName() -eq 'Invoke-VmPostProvisioning' } |
            Select-Object -First 1

        $ifAst = $call.Parent
        while ($null -ne $ifAst -and
               -not ($ifAst -is [System.Management.Automation.Language.IfStatementAst])) {
            $ifAst = $ifAst.Parent
        }

        $ifAst | Should -BeNullOrEmpty `
            -Because 'Invoke-VmPostProvisioning must be called for every VM; it self-skips when no opt-in fields are set'
    }

    It 'places Invoke-VmPostProvisioning after Invoke-VmCreation' {
        # Post-provisioning needs a running, SSH-reachable VM, which
        # Invoke-VmCreation guarantees by blocking until SSH is up.
        $byName = @{}
        foreach ($cmd in $script:commands) {
            $name = $cmd.GetCommandName()
            if ($name -in 'Invoke-VmCreation', 'Invoke-VmPostProvisioning') {
                if (-not $byName.ContainsKey($name)) {
                    $byName[$name] = $cmd.Extent.StartOffset
                }
            }
        }

        $byName['Invoke-VmCreation'] |
            Should -BeLessThan $byName['Invoke-VmPostProvisioning']
    }
}

Describe 'provision.ps1 - jump host wiring (feature 53 step 3 follow-up)' {

    # The host has no route into the per-environment private switch
    # after feature 53 step 2. provision.ps1 step 7 stamps the env's
    # router VM onto every workload as _RouterVm so create-vm.ps1's
    # wait-for-SSH and Invoke-VmPostProvisioning can open an SSH
    # tunnel through the router instead of trying (and failing) to
    # reach the workload IP directly.

    It 'pins Infrastructure.HyperV to the version that exports the jump-aware SSH helpers' {
        # New-VmSshTunnel / New-VmSshClientWithJump / Test-SshBanner
        # moved into Infrastructure.HyperV >= 0.11.0; provision.ps1 no
        # longer dot-sources them locally. Lock the MinimumVersion pin
        # here so a future downgrade does not break the load graph
        # silently (the helpers would resolve to whatever earlier
        # version was already on PSGallery and we would only catch it
        # at first jump-host invocation).
        $depsPath = Join-Path (Split-Path $script:provisionPath -Parent) `
            'Install-ModuleDependencies.ps1'
        $depsText = Get-Content -Path $depsPath -Raw
        $depsText | Should -Match "Infrastructure\.HyperV.*MinimumVersion\s+'0\.1[1-9]\.\d+'"
    }

    It 'stamps _RouterVm onto every workload in the network-setup loop' {
        # Regression guard: if a future refactor of the network-setup
        # step drops the Add-Member, create-vm.ps1 and Invoke-Vm-
        # PostProvisioning silently fall back to the direct-connect
        # branch and every workload's wait-for-SSH times out 10 min
        # later with no useful diagnosis. Three separate string
        # checks rather than one cross-line regex - PowerShell's
        # backtick continuations are not \s in regex char-class
        # terms, so a single pattern would have to special-case them.
        $text = Get-Content -Path $script:provisionPath -Raw
        $text | Should -Match "foreach\s*\(\s*\`$workload\s+in\s+\`$env\.WorkloadVms\s*\)"
        $text | Should -Match "-Name\s+'_RouterVm'"
        $text | Should -Match "-Value\s+\`$routerVm"
    }

    It 'places the _RouterVm stamping inside the host network setup phase' {
        # The router VM is mintable only inside the host-network-setup
        # loop (Group-VmsByEnvironment is what surfaces it). Anywhere
        # else in the file is a sign the loop's per-env router context
        # was lost. This pins the Add-Member's surrounding phase header.
        $text       = Get-Content -Path $script:provisionPath -Raw
        $phaseAt    = $text.IndexOf("Invoke-WithPhaseTimer -Name 'Host network setup'")
        $addMember  = $text.IndexOf("-Name '_RouterVm'")
        $phaseAt    | Should -BeGreaterThan -1
        $addMember  | Should -BeGreaterThan $phaseAt
    }
}

Describe 'provision.ps1 - new-vs-existing pipeline split' {

    # Pins each per-VM foreach to the right list variable so a regression
    # that swaps a destructive step onto $vmsToProcess (re-creating
    # existing VMs - data loss) or an additive step onto $newVms (silently
    # not reconciling existing VMs - the gap this whole refactor closes)
    # fails the suite.

    Context 'destructive steps must iterate $newVms' {

        It 'Invoke-DiskImageAcquisition iterates $newVms' {
            Get-LoopVarFor 'Invoke-DiskImageAcquisition' | Should -Be 'newVms'
        }

        It 'Invoke-SeedIsoGeneration iterates $newVms' {
            Get-LoopVarFor 'Invoke-SeedIsoGeneration' | Should -Be 'newVms'
        }

        It 'Invoke-VmCreation iterates $newVms' {
            Get-LoopVarFor 'Invoke-VmCreation' | Should -Be 'newVms'
        }
    }

    Context 'additive steps must iterate $vmsToProcess' {

        It 'Invoke-VmAcquisitions iterates $vmsToProcess' {
            Get-LoopVarFor 'Invoke-VmAcquisitions' | Should -Be 'vmsToProcess'
        }

        It 'Invoke-VmPostProvisioning iterates $vmsToProcess' {
            Get-LoopVarFor 'Invoke-VmPostProvisioning' | Should -Be 'vmsToProcess'
        }
    }
}
