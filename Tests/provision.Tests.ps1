<#
.SYNOPSIS
    Structural wiring checks for provision.ps1.

.DESCRIPTION
    provision.ps1 has top-level side effects (vault read, module imports) so
    it cannot be dot-sourced safely from a test. As a pragmatic compromise
    these tests parse the file via AST and assert that the JDK acquisition
    step is wired between disk acquisition and seed-ISO generation, and that
    the call is guarded by the optional 'javaDevKit' presence check.

    Behavioural coverage of Invoke-JdkAcquisition itself lives in
    Tests/up/jdk/Invoke-JdkAcquisition.Tests.ps1. An end-to-end assertion
    that a tarball actually lands in vhdPath is deferred to a future
    integration-test scaffold (none exists in this repo today).
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
}

Describe 'provision.ps1 - JDK wiring (Step 4)' {

    It 'dot-sources Invoke-JdkAcquisition.ps1' {
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

    It 'invokes Invoke-JdkAcquisition exactly once' {
        $jdkCalls = $script:commands |
            Where-Object { $_.GetCommandName() -eq 'Invoke-JdkAcquisition' }
        @($jdkCalls).Count | Should -Be 1
    }

    It 'guards Invoke-JdkAcquisition with a javaDevKit presence check' {
        # Locate the CommandAst, walk up to its enclosing IfStatementAst, and
        # assert that the if-condition mentions 'javaDevKit'. This catches the
        # mistake of calling Invoke-JdkAcquisition unconditionally (which
        # under StrictMode would throw on VMs without the field).
        $jdkCall = $script:commands |
            Where-Object { $_.GetCommandName() -eq 'Invoke-JdkAcquisition' } |
            Select-Object -First 1

        $jdkCall | Should -Not -BeNullOrEmpty

        $ifAst = $jdkCall.Parent
        while ($null -ne $ifAst -and
               -not ($ifAst -is [System.Management.Automation.Language.IfStatementAst])) {
            $ifAst = $ifAst.Parent
        }

        $ifAst | Should -Not -BeNullOrEmpty `
            -Because 'Invoke-JdkAcquisition must be inside an if-block'

        $conditionText = $ifAst.Clauses[0].Item1.Extent.Text
        $conditionText | Should -Match 'javaDevKit'
    }

    It 'places the JDK call after disk acquisition and before seed-ISO generation' {
        # Ordering matters: vhdPath is created by Invoke-DiskImageAcquisition,
        # and the seed-ISO generator consumes _jdkTarballPath produced by
        # Invoke-JdkAcquisition. Verify by call-site offsets in the file.
        $byName = @{}
        foreach ($cmd in $script:commands) {
            $name = $cmd.GetCommandName()
            if ($name -in 'Invoke-DiskImageAcquisition',
                          'Invoke-JdkAcquisition',
                          'Invoke-SeedIsoGeneration') {
                # Capture the first occurrence only - each command appears
                # exactly once inside its own foreach loop.
                if (-not $byName.ContainsKey($name)) {
                    $byName[$name] = $cmd.Extent.StartOffset
                }
            }
        }

        $byName['Invoke-DiskImageAcquisition'] |
            Should -BeLessThan $byName['Invoke-JdkAcquisition']
        $byName['Invoke-JdkAcquisition'] |
            Should -BeLessThan $byName['Invoke-SeedIsoGeneration']
    }
}
