BeforeAll {
    # Stub every primitive and helper the SUT calls into. Real
    # implementations live in Infrastructure.HyperV (Invoke-SshClientCommand,
    # Remove-VmSymlink) and in the reconciler folder (Read-VmManifest,
    # Remove-VmManifest); each is exercised by its own test suite.
    function Read-VmManifest         { param($SshClient, $Path) }
    function Invoke-SshClientCommand { param($SshClient, $Command) }
    function Remove-VmSymlink        { param($SshClient, $Path) }
    function Remove-VmManifest       { param($SshClient, $Path) }

    function ConvertTo-Array {
        param($InputObject)
        if ($null -eq $InputObject) { return ,@() }
        return ,@($InputObject)
    }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\dotnet\DotnetToolsProvider.Uninstall-Version.ps1"

    $script:FakeSshClient = [PSCustomObject]@{ }

    function New-Manifest {
        param(
            [string]   $Id            = 'dotnet-reportgenerator-globaltool',
            [string]   $RawVersion    = '5.4.4',
            [object[]] $OwnedSymlinks = @(
                @{ path = '/usr/local/bin/reportgenerator'; target = '/usr/local/share/dotnet/tools/reportgenerator' }
            )
        )
        [PSCustomObject]@{
            schemaVersion  = 1
            provider       = 'dotnetTools'
            version        = "$Id-$RawVersion"
            id             = $Id
            rawVersion     = $RawVersion
            ownedPaths     = @("/usr/local/share/dotnet/tools/.store/$Id/$RawVersion")
            ownedSymlinks  = @(
                $OwnedSymlinks | ForEach-Object {
                    [PSCustomObject]@{ path = $_.path; target = $_.target }
                }
            )
            commands       = @('reportgenerator')
            parentProvider = 'dotnetSdk'
        }
    }

    function New-Installed {
        param(
            [string] $Id           = 'dotnet-reportgenerator-globaltool',
            [string] $RawVersion   = '5.4.4',
            [string] $ManifestPath = '/var/lib/infra-provisioner/manifests/dotnetTools-dotnet-reportgenerator-globaltool-5.4.4.json'
        )
        [PSCustomObject]@{
            Provider     = 'dotnetTools'
            Version      = "$Id@$RawVersion"
            Id           = $Id
            RawVersion   = $RawVersion
            InstallPath  = "/usr/local/share/dotnet/tools/.store/$Id/$RawVersion"
            ManifestPath = $ManifestPath
            Symlinks     = @(
                [PSCustomObject]@{ path = '/usr/local/bin/reportgenerator'; target = '/usr/local/share/dotnet/tools/reportgenerator' }
            )
        }
    }

    function New-SshResult {
        param([int] $ExitStatus = 0, [string] $Output = '', [string] $Error = '')
        [PSCustomObject]@{ ExitStatus = $ExitStatus; Output = $Output; Error = $Error }
    }
}

Describe 'Uninstall-DotnetToolVersion' {

    BeforeEach {
        Mock Read-VmManifest         { New-Manifest }
        Mock Remove-VmSymlink        { }
        Mock Remove-VmManifest       { }
        # Default: probe returns the owned target (-> symlink is ours);
        # `dotnet tool uninstall` returns 0.
        Mock Invoke-SshClientCommand {
            if ($Command -match 'readlink') {
                New-SshResult -Output '/usr/local/share/dotnet/tools/reportgenerator'
            } else {
                New-SshResult
            }
        }
    }

    # ----------------------------------------------------------------------
    Context 'happy path - primitive wiring' {
    # ----------------------------------------------------------------------

        It 'reads the manifest from the Installed record''s ManifestPath' {
            Uninstall-DotnetToolVersion `
                -SshClient $script:FakeSshClient `
                -Installed (New-Installed)

            Should -Invoke Read-VmManifest -Times 1 -Exactly -ParameterFilter {
                $Path -eq '/var/lib/infra-provisioner/manifests/dotnetTools-dotnet-reportgenerator-globaltool-5.4.4.json'
            }
        }

        It 'removes a symlink whose current target points into the tools dir' {
            Uninstall-DotnetToolVersion `
                -SshClient $script:FakeSshClient `
                -Installed (New-Installed)

            Should -Invoke Remove-VmSymlink -Times 1 -Exactly -ParameterFilter {
                $Path -eq '/usr/local/bin/reportgenerator'
            }
        }

        It 'runs dotnet tool uninstall with id and --tool-path' {
            Uninstall-DotnetToolVersion `
                -SshClient $script:FakeSshClient `
                -Installed (New-Installed)

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match "dotnet tool uninstall 'dotnet-reportgenerator-globaltool'" -and
                $Command -match "--tool-path '/usr/local/share/dotnet/tools'"
            }
        }

        It 'removes the manifest last' {
            Uninstall-DotnetToolVersion `
                -SshClient $script:FakeSshClient `
                -Installed (New-Installed)

            Should -Invoke Remove-VmManifest -Times 1 -Exactly -ParameterFilter {
                $Path -eq '/var/lib/infra-provisioner/manifests/dotnetTools-dotnet-reportgenerator-globaltool-5.4.4.json'
            }
        }
    }

    # ----------------------------------------------------------------------
    Context 'ownership boundary' {
    # ----------------------------------------------------------------------

        It 'does NOT remove a symlink whose current target is outside the tools dir' {
            # Operator-side rebind: /usr/local/bin/reportgenerator now
            # points at a hand-built binary. Removing it would be
            # destructive; leave it in place and log.
            Mock Invoke-SshClientCommand {
                if ($Command -match 'readlink') {
                    New-SshResult -Output '/opt/custom/reportgenerator'
                } else {
                    New-SshResult
                }
            }

            Uninstall-DotnetToolVersion `
                -SshClient $script:FakeSshClient `
                -Installed (New-Installed) `
                -WarningAction SilentlyContinue

            Should -Not -Invoke Remove-VmSymlink
            # Manifest still removed - the provider's bookkeeping is
            # gone, and the foreign symlink is the operator's now.
            Should -Invoke Remove-VmManifest -Times 1
        }

        It 'does NOT remove an entry that is not a symlink' {
            # readlink returns empty string for a non-symlink (regular
            # file, missing path); the SUT must treat that as "not ours".
            Mock Invoke-SshClientCommand {
                if ($Command -match 'readlink') {
                    New-SshResult -Output ''
                } else {
                    New-SshResult
                }
            }

            Uninstall-DotnetToolVersion `
                -SshClient $script:FakeSshClient `
                -Installed (New-Installed)

            Should -Not -Invoke Remove-VmSymlink
        }
    }

    # ----------------------------------------------------------------------
    Context 'tolerance for already-absent tool' {
    # ----------------------------------------------------------------------

        It 'continues to manifest removal when dotnet tool uninstall exits non-zero' {
            # A stale install (manifest exists, .store/ slot already
            # gone) returns non-zero with "not installed" stderr. The
            # symlink + manifest cleanup are the load-bearing parts;
            # the .store/ slot freeing is best-effort.
            Mock Invoke-SshClientCommand {
                if ($Command -match 'dotnet tool uninstall') {
                    New-SshResult -ExitStatus 1 -Error 'A tool with the package id ... could not be uninstalled'
                } elseif ($Command -match 'readlink') {
                    New-SshResult -Output '/usr/local/share/dotnet/tools/reportgenerator'
                } else {
                    New-SshResult
                }
            }

            { Uninstall-DotnetToolVersion `
                -SshClient $script:FakeSshClient `
                -Installed (New-Installed) `
                -WarningAction SilentlyContinue } | Should -Not -Throw

            Should -Invoke Remove-VmManifest -Times 1
        }
    }

    # ----------------------------------------------------------------------
    Context 'ordering and crash safety' {
    # ----------------------------------------------------------------------

        It 'tears down in order: symlinks -> dotnet tool uninstall -> manifest' {
            $script:callOrder = New-Object System.Collections.Generic.List[string]
            Mock Remove-VmSymlink   { $script:callOrder.Add('symlink')  }
            Mock Remove-VmManifest  { $script:callOrder.Add('manifest') }
            Mock Invoke-SshClientCommand {
                if     ($Command -match 'dotnet tool uninstall') { $script:callOrder.Add('uninstall'); New-SshResult }
                elseif ($Command -match 'readlink')              { New-SshResult -Output '/usr/local/share/dotnet/tools/reportgenerator' }
                else                                              { New-SshResult }
            }

            Uninstall-DotnetToolVersion `
                -SshClient $script:FakeSshClient `
                -Installed (New-Installed)

            $symIdx       = $script:callOrder.IndexOf('symlink')
            $uninstallIdx = $script:callOrder.IndexOf('uninstall')
            $manIdx       = $script:callOrder.IndexOf('manifest')

            ($uninstallIdx -gt $symIdx)       | Should -BeTrue
            ($manIdx       -gt $uninstallIdx) | Should -BeTrue
        }

        It 'propagates a Read-VmManifest failure without touching the VM further' {
            Mock Read-VmManifest { throw 'Read-VmManifest: ... not found' }

            { Uninstall-DotnetToolVersion `
                -SshClient $script:FakeSshClient `
                -Installed (New-Installed) } |
                Should -Throw -ExpectedMessage '*not found*'

            Should -Not -Invoke Remove-VmSymlink
            Should -Not -Invoke Remove-VmManifest
        }
    }
}
