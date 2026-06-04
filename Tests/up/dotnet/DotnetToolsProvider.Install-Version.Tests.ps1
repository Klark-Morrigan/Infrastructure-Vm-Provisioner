BeforeAll {
    # Stub the primitives the SUT calls into. Real implementations live
    # in Infrastructure.HyperV (Add-VmFileServerFile, Invoke-SshClientCommand,
    # New-VmSymlink) and in the reconciler folder (Write-VmManifest);
    # each is exercised by its own test suite, so this file only
    # verifies orchestration (call shape, manifest contents, ordering,
    # parsing).
    function Add-VmFileServerFile  { param($Server, $LocalPath) }
    function Invoke-SshClientCommand { param($SshClient, $Command) }
    function New-VmSymlink          { param($SshClient, $Path, $Target) }
    function Write-VmManifest       { param($SshClient, $Manifest) }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\dotnet\DotnetToolsProvider.Install-Version.ps1"

    $script:FakeSshClient = [PSCustomObject]@{ }
    $script:FakeServer    = [PSCustomObject]@{ BaseUrl = 'http://192.168.1.1:8745' }

    function New-ToolSpec {
        param(
            [string] $Id        = 'dotnet-reportgenerator-globaltool',
            [string] $Version   = '5.4.4',
            [string] $NupkgPath = 'C:\cache\dotnet-tool-dotnet-reportgenerator-globaltool-5.4.4.nupkg'
        )
        [PSCustomObject]@{
            Provider   = 'dotnetTools'
            Version    = "$Id@$Version"
            Id         = $Id
            RawVersion = $Version
            NupkgPath  = $NupkgPath
        }
    }

    # Realistic `dotnet tool list --tool-path ...` output for the
    # reportgenerator install. The driver pads the columns with spaces;
    # the parser must tolerate variable spacing.
    $script:ListOutput = @'
Package Id                              Version      Commands
---------------------------------------------------------------
dotnet-reportgenerator-globaltool       5.4.4        reportgenerator
'@

    # Default mock for Invoke-SshClientCommand: matches every command and
    # returns ExitStatus 0. Tests override per-command via -ParameterFilter
    # to drive specific shapes (e.g. the list step needs Output populated).
    function New-SshResult {
        param([int] $ExitStatus = 0, [string] $Output = '', [string] $Error = '')
        [PSCustomObject]@{
            ExitStatus = $ExitStatus
            Output     = $Output
            Error      = $Error
        }
    }
}

Describe 'Install-DotnetToolVersion' {

    BeforeEach {
        Mock Add-VmFileServerFile { 'http://192.168.1.1:8745/nupkg' }
        Mock New-VmSymlink        { }
        Mock Write-VmManifest     { }
        # General catch-all - returns success and the list output for
        # the list command. Specific tests can shadow with narrower
        # -ParameterFilter mocks.
        Mock Invoke-SshClientCommand {
            if ($Command -match 'dotnet tool list') {
                New-SshResult -Output $script:ListOutput
            } else {
                New-SshResult
            }
        }
    }

    # ----------------------------------------------------------------------
    Context 'happy path - primitive wiring' {
    # ----------------------------------------------------------------------

        It 'stages the cached .nupkg via Add-VmFileServerFile' {
            Install-DotnetToolVersion `
                -SshClient $script:FakeSshClient `
                -Server    $script:FakeServer `
                -Spec      (New-ToolSpec)

            Should -Invoke Add-VmFileServerFile -Times 1 -Exactly -ParameterFilter {
                $LocalPath -eq 'C:\cache\dotnet-tool-dotnet-reportgenerator-globaltool-5.4.4.nupkg'
            }
        }

        It 'downloads the staged URL into a per-tool staging dir on the VM' {
            Install-DotnetToolVersion `
                -SshClient $script:FakeSshClient `
                -Server    $script:FakeServer `
                -Spec      (New-ToolSpec)

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match 'mkdir -p' -and
                $Command -match '/var/lib/infra-provisioner/staging/dotnet-tools/dotnet-reportgenerator-globaltool@5\.4\.4' -and
                $Command -match 'curl -fsSL' -and
                $Command -match 'http://192\.168\.1\.1:8745/nupkg'
            }
        }

        It 'writes the staged .nupkg under the canonical {idLower}.{version}.nupkg filename' {
            Install-DotnetToolVersion `
                -SshClient $script:FakeSshClient `
                -Server    $script:FakeServer `
                -Spec      (New-ToolSpec)

            # NuGet's local-source enumerator matches files by parsing
            # '{id}.{version}.nupkg'; the host-cache filename
            # ('dotnet-tool-{id}-{version}.nupkg') does not match and the
            # resolver would otherwise report "not found in NuGet feeds
            # <stagingDir>" despite the file being present.
            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match "tee '/var/lib/infra-provisioner/staging/dotnet-tools/dotnet-reportgenerator-globaltool@5\.4\.4/dotnet-reportgenerator-globaltool\.5\.4\.4\.nupkg'"
            }
        }

        It 'runs dotnet tool install with the expected argument vector' {
            Install-DotnetToolVersion `
                -SshClient $script:FakeSshClient `
                -Server    $script:FakeServer `
                -Spec      (New-ToolSpec)

            # --configfile pins the resolver to the staging-dir NuGet.Config
            # (which has <clear /> + the staging dir), so neither
            # --add-source nor --ignore-failed-sources are needed; their
            # absence is what stops the resolver from probing api.nuget.org.
            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match "dotnet tool install 'dotnet-reportgenerator-globaltool'" -and
                $Command -match "--tool-path '/usr/local/share/dotnet/tools'" -and
                $Command -match "--configfile '/var/lib/infra-provisioner/staging/dotnet-tools/dotnet-reportgenerator-globaltool@5\.4\.4/NuGet\.Config'" -and
                $Command -match "--version '5\.4\.4'" -and
                $Command -notmatch '--add-source' -and
                $Command -notmatch '--ignore-failed-sources'
            }
        }

        It 'writes a NuGet.Config pinning the staging dir as the sole package source' {
            Install-DotnetToolVersion `
                -SshClient $script:FakeSshClient `
                -Server    $script:FakeServer `
                -Spec      (New-ToolSpec)

            # The staging script tees a NuGet.Config into the staging dir.
            # <clear /> drops ambient nuget.org; the single <add /> entry
            # points at the same staging dir the .nupkg was just written
            # to. Together these two lines are what keeps the VM install
            # offline.
            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match "tee '/var/lib/infra-provisioner/staging/dotnet-tools/dotnet-reportgenerator-globaltool@5\.4\.4/NuGet\.Config'" -and
                $Command -match '<clear />' -and
                $Command -match 'value="/var/lib/infra-provisioner/staging/dotnet-tools/dotnet-reportgenerator-globaltool@5\.4\.4"'
            }
        }

        It 'enumerates installed commands via dotnet tool list' {
            Install-DotnetToolVersion `
                -SshClient $script:FakeSshClient `
                -Server    $script:FakeServer `
                -Spec      (New-ToolSpec)

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match 'dotnet tool list' -and
                $Command -match "--tool-path '/usr/local/share/dotnet/tools'"
            }
        }

        It 'creates one /usr/local/bin symlink per discovered command, targeting the tools dir' {
            Install-DotnetToolVersion `
                -SshClient $script:FakeSshClient `
                -Server    $script:FakeServer `
                -Spec      (New-ToolSpec)

            Should -Invoke New-VmSymlink -Times 1 -Exactly -ParameterFilter {
                $Path   -eq '/usr/local/bin/reportgenerator' -and
                $Target -eq '/usr/local/share/dotnet/tools/reportgenerator'
            }
        }

        It 'writes a manifest with composite version, ownedPaths into .store, symlinks, commands, parentProvider' {
            Install-DotnetToolVersion `
                -SshClient $script:FakeSshClient `
                -Server    $script:FakeServer `
                -Spec      (New-ToolSpec)

            Should -Invoke Write-VmManifest -Times 1 -Exactly -ParameterFilter {
                $Manifest.schemaVersion                  -eq 1               -and
                $Manifest.provider                       -eq 'dotnetTools'   -and
                # Composite drives the filename token; raw id and version
                # carried separately.
                $Manifest.version                        -eq 'dotnet-reportgenerator-globaltool-5.4.4' -and
                $Manifest.id                             -eq 'dotnet-reportgenerator-globaltool' -and
                $Manifest.rawVersion                     -eq '5.4.4'         -and
                @($Manifest.ownedPaths)[0]               -eq '/usr/local/share/dotnet/tools/.store/dotnet-reportgenerator-globaltool/5.4.4' -and
                @($Manifest.ownedSymlinks)[0].path       -eq '/usr/local/bin/reportgenerator' -and
                @($Manifest.ownedSymlinks)[0].target     -eq '/usr/local/share/dotnet/tools/reportgenerator' -and
                @($Manifest.commands)[0]                 -eq 'reportgenerator' -and
                $Manifest.parentProvider                 -eq 'dotnetSdk'     -and
                @($Manifest.children).Count              -eq 0
            }
        }

        It 'wipes the staging dir after a successful install' {
            Install-DotnetToolVersion `
                -SshClient $script:FakeSshClient `
                -Server    $script:FakeServer `
                -Spec      (New-ToolSpec)

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match 'rm -rf' -and
                $Command -match '/var/lib/infra-provisioner/staging/dotnet-tools/dotnet-reportgenerator-globaltool@5\.4\.4'
            }
        }
    }

    # ----------------------------------------------------------------------
    Context 'ordering and crash safety' {
    # ----------------------------------------------------------------------

        It 'writes the manifest AFTER install + symlink and BEFORE staging cleanup' {
            $script:callOrder = New-Object System.Collections.Generic.List[string]
            Mock Invoke-SshClientCommand {
                if     ($Command -match 'rm -rf')           { $script:callOrder.Add('cleanup'); New-SshResult }
                elseif ($Command -match 'dotnet tool install') { $script:callOrder.Add('install'); New-SshResult }
                elseif ($Command -match 'dotnet tool list')    { $script:callOrder.Add('list');    New-SshResult -Output $script:ListOutput }
                elseif ($Command -match 'curl')             { $script:callOrder.Add('stage');   New-SshResult }
                else                                         { New-SshResult }
            }
            Mock New-VmSymlink     { $script:callOrder.Add('symlink')  }
            Mock Write-VmManifest  { $script:callOrder.Add('manifest') }

            Install-DotnetToolVersion `
                -SshClient $script:FakeSshClient `
                -Server    $script:FakeServer `
                -Spec      (New-ToolSpec)

            $stageIdx   = $script:callOrder.IndexOf('stage')
            $installIdx = $script:callOrder.IndexOf('install')
            $listIdx    = $script:callOrder.IndexOf('list')
            $symIdx     = $script:callOrder.IndexOf('symlink')
            $manIdx     = $script:callOrder.IndexOf('manifest')
            $cleanIdx   = $script:callOrder.IndexOf('cleanup')

            ($installIdx -gt $stageIdx)   | Should -BeTrue
            ($listIdx    -gt $installIdx) | Should -BeTrue
            ($symIdx     -gt $listIdx)    | Should -BeTrue
            ($manIdx     -gt $symIdx)     | Should -BeTrue
            ($cleanIdx   -gt $manIdx)     | Should -BeTrue
        }

        It 'throws and skips install + manifest when staging fails' {
            Mock Invoke-SshClientCommand {
                if ($Command -match 'curl') {
                    New-SshResult -ExitStatus 1 -Error 'curl: (7) Failed to connect'
                } else {
                    New-SshResult
                }
            }

            { Install-DotnetToolVersion `
                -SshClient $script:FakeSshClient `
                -Server    $script:FakeServer `
                -Spec      (New-ToolSpec) } |
                Should -Throw -ExpectedMessage '*staging*Failed to connect*'

            Should -Not -Invoke Invoke-SshClientCommand -ParameterFilter { $Command -match 'dotnet tool install' }
            Should -Not -Invoke New-VmSymlink
            Should -Not -Invoke Write-VmManifest
        }

        It 'throws and skips list + symlink + manifest when dotnet tool install fails' {
            Mock Invoke-SshClientCommand {
                if ($Command -match 'dotnet tool install') {
                    New-SshResult -ExitStatus 1 -Error 'install error'
                } else {
                    New-SshResult
                }
            }

            { Install-DotnetToolVersion `
                -SshClient $script:FakeSshClient `
                -Server    $script:FakeServer `
                -Spec      (New-ToolSpec) } |
                Should -Throw -ExpectedMessage '*dotnet tool install*install error*'

            Should -Not -Invoke Invoke-SshClientCommand -ParameterFilter { $Command -match 'dotnet tool list' }
            Should -Not -Invoke New-VmSymlink
            Should -Not -Invoke Write-VmManifest
        }

        It 'throws if dotnet tool list does not report the just-installed tool' {
            # Defensive: a broken parser or an off-by-one in --tool-path
            # would otherwise silently produce a manifest with zero
            # symlinks and orphan the install.
            Mock Invoke-SshClientCommand {
                if ($Command -match 'dotnet tool list') {
                    New-SshResult -Output "Package Id    Version    Commands`n----`nsome-other-tool    1.0.0    other"
                } else {
                    New-SshResult
                }
            }

            { Install-DotnetToolVersion `
                -SshClient $script:FakeSshClient `
                -Server    $script:FakeServer `
                -Spec      (New-ToolSpec) } |
                Should -Throw -ExpectedMessage '*did not report any commands*'

            Should -Not -Invoke New-VmSymlink
            Should -Not -Invoke Write-VmManifest
        }

        It 'logs a warning and continues when staging cleanup fails' {
            # Cleanup is best-effort: the tool is installed and the
            # manifest is written, so a stuck staging dir is a leak,
            # not a failure.
            Mock Invoke-SshClientCommand {
                if ($Command -match 'rm -rf') {
                    New-SshResult -ExitStatus 1 -Error 'rm: cannot remove'
                } elseif ($Command -match 'dotnet tool list') {
                    New-SshResult -Output $script:ListOutput
                } else {
                    New-SshResult
                }
            }

            { Install-DotnetToolVersion `
                -SshClient $script:FakeSshClient `
                -Server    $script:FakeServer `
                -Spec      (New-ToolSpec) } | Should -Not -Throw

            Should -Invoke Write-VmManifest -Times 1
        }
    }

    # ----------------------------------------------------------------------
    Context 'tool list parser' {
    # ----------------------------------------------------------------------

        It 'returns the command for a single-command tool' {
            $cmds = Get-DotnetToolCommandsFromListOutput `
                        -Output $script:ListOutput `
                        -Id     'dotnet-reportgenerator-globaltool'
            @($cmds).Count | Should -Be 1
            $cmds[0]       | Should -Be 'reportgenerator'
        }

        It 'is case-insensitive on the package id match' {
            $cmds = Get-DotnetToolCommandsFromListOutput `
                        -Output $script:ListOutput `
                        -Id     'DOTNET-ReportGenerator-GlobalTool'
            @($cmds).Count | Should -Be 1
        }

        It 'returns @() when the id is not in the list' {
            $cmds = Get-DotnetToolCommandsFromListOutput `
                        -Output $script:ListOutput `
                        -Id     'does-not-exist'
            ,$cmds -is [array] | Should -BeTrue
            @($cmds).Count     | Should -Be 0
        }

        It 'splits a multi-command Commands column on whitespace and commas' {
            $multi = @'
Package Id    Version    Commands
----------------------------------
multi-tool    1.0.0      first, second third
'@
            $cmds = Get-DotnetToolCommandsFromListOutput -Output $multi -Id 'multi-tool'
            @($cmds).Count | Should -Be 3
            $cmds          | Should -Contain 'first'
            $cmds          | Should -Contain 'second'
            $cmds          | Should -Contain 'third'
        }
    }
}
