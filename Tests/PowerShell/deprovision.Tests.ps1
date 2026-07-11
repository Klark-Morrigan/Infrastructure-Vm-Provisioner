<#
.SYNOPSIS
    Structural wiring checks for deprovision.ps1.

.DESCRIPTION
    deprovision.ps1 has top-level side effects (vault read via the helper,
    module imports) so it cannot be dot-sourced safely from a test. As a
    pragmatic compromise these tests parse the file via AST and assert:
      - The vault-bootstrap is delegated to Read-VmProvisionerConfig
        (no direct SecretManagement calls).
      - Per-VM removal runs before per-environment network teardown so
        VMs are not stranded by an early switch removal.

    Behavioural coverage of the called functions lives next to each one
    (Tests/common/config/Read-VmProvisionerConfig.Tests.ps1,
    Tests/down/vm/Invoke-VmRemoval.Tests.ps1,
    Tests/down/network/Invoke-NetworkTeardown.Tests.ps1).
#>

BeforeAll {
    $script:deprovisionPath = Join-Path $PSScriptRoot `
        '..\..\hyper-v\ubuntu\PowerShell\deprovision.ps1'

    $tokens    = $null
    $parseErrs = $null
    $script:ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:deprovisionPath, [ref] $tokens, [ref] $parseErrs)

    if ($parseErrs.Count -gt 0) {
        throw "deprovision.ps1 has parse errors: $($parseErrs -join '; ')"
    }

    # Pull every command invocation in the file once so each test can filter
    # cheaply by command name.
    $script:commands = $script:ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
    }, $true)
}

Describe 'deprovision.ps1 - bootstrap wiring (Read-VmProvisionerConfig)' {

    # The vault read / SecretManagement bootstrap was extracted to
    # common/config/Read-VmProvisionerConfig.ps1. These tests pin the
    # delegation so a future change cannot silently reintroduce the inline
    # vault-handling code (which would split error wording across two
    # places and break the helper's test coverage).

    It 'dot-sources Read-VmProvisionerConfig.ps1' {
        $text = Get-Content -Path $script:deprovisionPath -Raw
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

    It 'does not import SecretManagement modules directly (helper owns it)' {
        $calls = $script:commands |
            Where-Object { $_.GetCommandName() -eq 'Import-Module' }
        @($calls).Count | Should -Be 0 `
            -Because 'SecretManagement / SecretStore imports moved into Read-VmProvisionerConfig'
    }

    # See provision.Tests.ps1 for the suffix-forwarding rationale.

    It 'declares -SecretSuffix as a mandatory script parameter' {
        $param = $script:ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'SecretSuffix' } |
            Select-Object -First 1
        $param | Should -Not -BeNullOrEmpty
        $hasMandatory = $param.Attributes | Where-Object {
            $_.TypeName.Name -eq 'Parameter' -and
            ($_.NamedArguments | Where-Object {
                $_.ArgumentName -eq 'Mandatory'
            })
        }
        $hasMandatory | Should -Not -BeNullOrEmpty
    }

    It 'forwards the script-level $SecretSuffix to Read-VmProvisionerConfig' {
        $call = $script:commands |
            Where-Object { $_.GetCommandName() -eq 'Read-VmProvisionerConfig' } |
            Select-Object -First 1
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
        $forwarded | Should -BeTrue
    }
}

Describe 'deprovision.ps1 - teardown wiring' {

    It 'dot-sources remove-vm.ps1 (Invoke-VmRemoval)' {
        $text = Get-Content -Path $script:deprovisionPath -Raw
        $text | Should -Match 'remove-vm\.ps1'
    }

    It 'dot-sources teardown-network.ps1 (Invoke-NetworkTeardown)' {
        $text = Get-Content -Path $script:deprovisionPath -Raw
        $text | Should -Match 'teardown-network\.ps1'
    }

    It 'invokes Invoke-VmRemoval exactly once (inside a foreach loop)' {
        $calls = $script:commands |
            Where-Object { $_.GetCommandName() -eq 'Invoke-VmRemoval' }
        @($calls).Count | Should -Be 1

        # Walk up to the enclosing foreach so a regression that drops the
        # loop (and only deprovisions the first VM) fails loudly.
        $node = $calls[0].Parent
        while ($null -ne $node -and
               -not ($node -is [System.Management.Automation.Language.ForEachStatementAst])) {
            $node = $node.Parent
        }
        $node | Should -Not -BeNullOrEmpty `
            -Because 'Invoke-VmRemoval must run per-VM via a foreach'
    }

    It 'invokes Invoke-NetworkTeardown inside a foreach loop' {
        # Per-environment teardown: deprovision groups vmDefs by
        # privateSwitchName and calls Invoke-NetworkTeardown once per
        # group. A regression that flattens the loop would tear down
        # only the first environment's network state.
        $calls = $script:commands |
            Where-Object { $_.GetCommandName() -eq 'Invoke-NetworkTeardown' }
        @($calls).Count | Should -Be 1

        $node = $calls[0].Parent
        while ($null -ne $node -and
               -not ($node -is [System.Management.Automation.Language.ForEachStatementAst])) {
            $node = $node.Parent
        }
        $node | Should -Not -BeNullOrEmpty `
            -Because 'Invoke-NetworkTeardown must run per-environment via a foreach'
    }
}

Describe 'deprovision.ps1 - phase ordering' {

    # Pins the source-order relationship between the load-bearing
    # phases. A regression that swaps either pair would either read VM
    # defs after the per-VM loop, or remove the Private switch out from
    # under a VM still being shut down.

    It 'reads config before removing any VM' {
        $byName = @{}
        foreach ($cmd in $script:commands) {
            $name = $cmd.GetCommandName()
            if ($name -in 'Read-VmProvisionerConfig', 'Invoke-VmRemoval') {
                if (-not $byName.ContainsKey($name)) {
                    $byName[$name] = $cmd.Extent.StartOffset
                }
            }
        }
        $byName['Read-VmProvisionerConfig'] |
            Should -BeLessThan $byName['Invoke-VmRemoval']
    }

    It 'removes every VM before tearing the per-environment network down' {
        # Network teardown removes the Private switch when empty; running
        # it before per-VM removal would cut connectivity to VMs that
        # still need to be stopped/removed gracefully.
        $byName = @{}
        foreach ($cmd in $script:commands) {
            $name = $cmd.GetCommandName()
            if ($name -in 'Invoke-VmRemoval', 'Invoke-NetworkTeardown') {
                if (-not $byName.ContainsKey($name)) {
                    $byName[$name] = $cmd.Extent.StartOffset
                }
            }
        }
        $byName['Invoke-VmRemoval'] |
            Should -BeLessThan $byName['Invoke-NetworkTeardown']
    }
}
