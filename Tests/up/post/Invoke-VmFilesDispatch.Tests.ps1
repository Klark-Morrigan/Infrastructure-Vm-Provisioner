# PSAvoidGlobalVars is suppressed file-wide: the $global: invocation log
# and the global stub cmdlets below are the test-double trackers that
# shadow the Infrastructure.HyperV module functions. Global scope is
# required so the stubs and their log survive Pester v5's per-container
# scope boundaries; a script-scoped tracker is not visible to the stubs.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'Pester v5 cross-scope mock-call trackers')]
param()

BeforeAll {
    # Stub the cmdlets Invoke-VmFilesDispatch resolves by name. In
    # production they come from the Infrastructure.HyperV module
    # (Copy-VmFiles, Copy-VmFilesByPattern); the stubs here track
    # calls so the tests can assert routing decisions without a real
    # SSH session.
    $global:_FilesDispatch_Calls = @{
        'Copy-VmFiles'           = @()
        'Copy-VmFilesByPattern'  = @()
    }
    function global:Copy-VmFiles {
        param($SshClient, $Server, $Entries)
        $global:_FilesDispatch_Calls['Copy-VmFiles'] += @{
            Entries = $Entries
        }
    }
    function global:Copy-VmFilesByPattern {
        param($SshClient, $Server, $Pattern, $TargetDir,
              [switch]$Recurse, [switch]$PreserveRelativePath)
        $global:_FilesDispatch_Calls['Copy-VmFilesByPattern'] += @{
            Pattern              = $Pattern
            TargetDir            = $TargetDir
            Recurse              = [bool]$Recurse
            PreserveRelativePath = [bool]$PreserveRelativePath
        }
    }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\post\Invoke-VmFilesDispatch.ps1"

    function Reset-FilesDispatchCalls {
        foreach ($k in @($global:_FilesDispatch_Calls.Keys)) {
            $global:_FilesDispatch_Calls[$k] = @()
        }
    }

    function New-SingleEntry {
        param([string] $Source = 'C:\src\a', [string] $Target = '/opt/a')
        [PSCustomObject]@{ source = $Source; target = $Target }
    }
    function New-BulkEntry {
        param(
            [string] $Pattern   = 'C:\src\*.jar',
            [string] $TargetDir = '/opt/jars',
            [nullable[bool]] $Recurse              = $null,
            [nullable[bool]] $PreserveRelativePath = $null
        )
        $entry = [PSCustomObject]@{ pattern = $Pattern; targetDir = $TargetDir }
        if ($null -ne $Recurse) {
            $entry | Add-Member -NotePropertyName 'recurse' -NotePropertyValue $Recurse
        }
        if ($null -ne $PreserveRelativePath) {
            $entry | Add-Member -NotePropertyName 'preserveRelativePath' `
                                -NotePropertyValue $PreserveRelativePath
        }
        $entry
    }
}

Describe 'Invoke-VmFilesDispatch' {

    BeforeEach { Reset-FilesDispatchCalls }

    Context 'routing by entry shape' {

        It 'routes a single { source, target } entry to Copy-VmFiles' {
            Invoke-VmFilesDispatch `
                -SshClient ([PSCustomObject]@{}) -Server ([PSCustomObject]@{}) `
                -Entries @( (New-SingleEntry) )

            $global:_FilesDispatch_Calls['Copy-VmFiles'].Count          | Should -Be 1
            $global:_FilesDispatch_Calls['Copy-VmFilesByPattern'].Count | Should -Be 0
        }

        It 'routes a bulk { pattern, targetDir } entry to Copy-VmFilesByPattern' {
            Invoke-VmFilesDispatch `
                -SshClient ([PSCustomObject]@{}) -Server ([PSCustomObject]@{}) `
                -Entries @( (New-BulkEntry) )

            $global:_FilesDispatch_Calls['Copy-VmFilesByPattern'].Count | Should -Be 1
            $global:_FilesDispatch_Calls['Copy-VmFiles'].Count          | Should -Be 0
        }

        It 'discriminates on presence of `pattern` (not by entry type)' {
            # Same target dir, different shape - the entry with `pattern`
            # MUST be treated as bulk regardless of the other entry.
            Invoke-VmFilesDispatch `
                -SshClient ([PSCustomObject]@{}) -Server ([PSCustomObject]@{}) `
                -Entries @(
                    (New-SingleEntry),
                    (New-BulkEntry -Pattern 'C:\b\*' -TargetDir '/opt/b')
                )

            $global:_FilesDispatch_Calls['Copy-VmFiles'].Count          | Should -Be 1
            $global:_FilesDispatch_Calls['Copy-VmFilesByPattern'].Count | Should -Be 1
        }
    }

    Context 'JSON ordering' {

        It 'dispatches entries in the order they are passed (mixed [single, bulk, single])' {
            # The ordering contract is operator-visible: per-entry
            # routing rather than "all singles then all bulks" so the
            # log + side-effects appear in JSON order.
            $script:_calls = @()
            function global:Copy-VmFiles {
                param($SshClient, $Server, $Entries)
                $script:_calls += "single:$($Entries[0].Source)"
            }
            function global:Copy-VmFilesByPattern {
                param($SshClient, $Server, $Pattern, $TargetDir,
                      [switch]$Recurse, [switch]$PreserveRelativePath)
                $script:_calls += "bulk:$Pattern"
            }
            try {
                Invoke-VmFilesDispatch `
                    -SshClient ([PSCustomObject]@{}) -Server ([PSCustomObject]@{}) `
                    -Entries @(
                        (New-SingleEntry -Source 'C:\1'),
                        (New-BulkEntry   -Pattern 'C:\2\*'),
                        (New-SingleEntry -Source 'C:\3')
                    )

                $script:_calls | Should -Be @('single:C:\1', 'bulk:C:\2\*', 'single:C:\3')
            } finally {
                # Restore the tracking stubs for any subsequent tests.
                function global:Copy-VmFiles {
                    param($SshClient, $Server, $Entries)
                    $global:_FilesDispatch_Calls['Copy-VmFiles'] += @{ Entries = $Entries }
                }
                function global:Copy-VmFilesByPattern {
                    param($SshClient, $Server, $Pattern, $TargetDir,
                          [switch]$Recurse, [switch]$PreserveRelativePath)
                    $global:_FilesDispatch_Calls['Copy-VmFilesByPattern'] += @{
                        Pattern              = $Pattern
                        TargetDir            = $TargetDir
                        Recurse              = [bool]$Recurse
                        PreserveRelativePath = [bool]$PreserveRelativePath
                    }
                }
            }
        }
    }

    Context 'bulk-entry optional flags default to false' {
        # The JSON schema is a pure pass-through - the validator does
        # not inject defaults. Defaults applied here let the validator
        # stay pure and the dispatch stay deterministic.

        It 'defaults recurse to $false when absent on the entry' {
            Invoke-VmFilesDispatch `
                -SshClient ([PSCustomObject]@{}) -Server ([PSCustomObject]@{}) `
                -Entries @( (New-BulkEntry) )

            $global:_FilesDispatch_Calls['Copy-VmFilesByPattern'][0].Recurse |
                Should -Be $false
        }

        It 'defaults preserveRelativePath to $false when absent on the entry' {
            Invoke-VmFilesDispatch `
                -SshClient ([PSCustomObject]@{}) -Server ([PSCustomObject]@{}) `
                -Entries @( (New-BulkEntry) )

            $global:_FilesDispatch_Calls['Copy-VmFilesByPattern'][0].PreserveRelativePath |
                Should -Be $false
        }

        It 'forwards recurse=true when set on the entry' {
            Invoke-VmFilesDispatch `
                -SshClient ([PSCustomObject]@{}) -Server ([PSCustomObject]@{}) `
                -Entries @( (New-BulkEntry -Recurse $true) )

            $global:_FilesDispatch_Calls['Copy-VmFilesByPattern'][0].Recurse |
                Should -Be $true
        }

        It 'forwards preserveRelativePath=true when set on the entry' {
            Invoke-VmFilesDispatch `
                -SshClient ([PSCustomObject]@{}) -Server ([PSCustomObject]@{}) `
                -Entries @( (New-BulkEntry -PreserveRelativePath $true) )

            $global:_FilesDispatch_Calls['Copy-VmFilesByPattern'][0].PreserveRelativePath |
                Should -Be $true
        }
    }
}
