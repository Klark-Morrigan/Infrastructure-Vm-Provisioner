BeforeAll {
    # Stub every primitive and helper the SUT calls into. The real
    # implementations live in Infrastructure.HyperV (Stop-VmProcessesUsingPath,
    # Remove-VmSymlink, Remove-VmProfileDScript, Remove-VmDirectory) and
    # in the reconciler folder (Read-VmManifest, Remove-VmManifest);
    # each is exercised by its own test suite, so this file only verifies
    # orchestration: ordering, manifest fan-out, fail-safe semantics on
    # the Stop step, and fail-fast on the directory removal.
    function Read-VmManifest             { param($SshClient, $Path) }
    function Stop-VmProcessesUsingPath   { param($SshClient, $Path, $GraceSeconds) }
    function Remove-VmSymlink            { param($SshClient, $Path) }
    function Remove-VmProfileDScript     { param($SshClient, $Name) }
    function Remove-VmDirectory          { param($SshClient, $Path) }
    function Remove-VmManifest           { param($SshClient, $Path) }

    # ConvertTo-Array ships in Infrastructure.Common in production. The
    # SUT relies on it to keep the manifest sub-arrays array-shaped.
    function ConvertTo-Array {
        param([Parameter(ValueFromPipeline)] $InputObject)
        if ($null -eq $InputObject) { return ,@() }
        return ,@($InputObject)
    }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\dotnet\DotnetSdkProvider.Uninstall-Version.ps1"

    $script:FakeSshClient = [PSCustomObject]@{ }

    # A canonical manifest with one install dir, one symlink, one
    # profile.d script - mirrors what DotnetSdkProvider.Install-Version
    # writes for a 10.0.100 install. ConvertFrom-Json produces
    # PSCustomObject graphs, matching what Read-VmManifest returns in
    # production.
    function New-Manifest {
        param(
            [string[]] $OwnedPaths    = @('/opt/dotnet-10.0.100'),
            [object[]] $OwnedSymlinks = @(
                @{ path = '/usr/local/bin/dotnet'; target = '/opt/dotnet-10.0.100/dotnet' }
            ),
            [string[]] $OwnedProfileScripts = @('dotnet')
        )
        [PSCustomObject]@{
            schemaVersion       = 1
            provider            = 'dotnetSdk'
            version             = '10.0.100'
            ownedPaths          = $OwnedPaths
            ownedSymlinks       = @(
                $OwnedSymlinks | ForEach-Object {
                    [PSCustomObject]@{ path = $_.path; target = $_.target }
                }
            )
            ownedProfileScripts = $OwnedProfileScripts
            children            = @()
        }
    }

    function New-Installed {
        [PSCustomObject]@{
            Provider     = 'dotnetSdk'
            Version      = '10.0.100'
            InstallPath  = '/opt/dotnet-10.0.100'
            ManifestPath = '/var/lib/infra-provisioner/manifests/dotnetSdk-10.0.100.json'
        }
    }
}

Describe 'Uninstall-DotnetSdkVersion' {

    BeforeEach {
        Mock Read-VmManifest           { New-Manifest }
        Mock Stop-VmProcessesUsingPath { }
        Mock Remove-VmSymlink          { }
        Mock Remove-VmProfileDScript   { }
        Mock Remove-VmDirectory        { }
        Mock Remove-VmManifest         { }
    }

    # ----------------------------------------------------------------------
    Context 'happy path - primitive wiring' {
    # ----------------------------------------------------------------------

        It 'reads the manifest from the Installed record''s ManifestPath' {
            Uninstall-DotnetSdkVersion `
                -SshClient $script:FakeSshClient `
                -Installed (New-Installed)

            Should -Invoke Read-VmManifest -Times 1 -Exactly -ParameterFilter {
                $Path -eq '/var/lib/infra-provisioner/manifests/dotnetSdk-10.0.100.json'
            }
        }

        It 'drains processes off every ownedPaths entry with a 30s grace' {
            Uninstall-DotnetSdkVersion `
                -SshClient $script:FakeSshClient `
                -Installed (New-Installed)

            Should -Invoke Stop-VmProcessesUsingPath -Times 1 -Exactly -ParameterFilter {
                $Path         -eq '/opt/dotnet-10.0.100' -and
                $GraceSeconds -eq 30
            }
        }

        It 'removes the /usr/local/bin/dotnet symlink recorded in the manifest' {
            Uninstall-DotnetSdkVersion `
                -SshClient $script:FakeSshClient `
                -Installed (New-Installed)

            Should -Invoke Remove-VmSymlink -Times 1 -Exactly -ParameterFilter {
                $Path -eq '/usr/local/bin/dotnet'
            }
        }

        It 'removes every ownedProfileScripts entry by name' {
            Uninstall-DotnetSdkVersion `
                -SshClient $script:FakeSshClient `
                -Installed (New-Installed)

            Should -Invoke Remove-VmProfileDScript -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'dotnet'
            }
        }

        It 'removes every install directory after the lighter teardown' {
            Uninstall-DotnetSdkVersion `
                -SshClient $script:FakeSshClient `
                -Installed (New-Installed)

            Should -Invoke Remove-VmDirectory -Times 1 -Exactly -ParameterFilter {
                $Path -eq '/opt/dotnet-10.0.100'
            }
        }

        It 'removes the manifest last' {
            Uninstall-DotnetSdkVersion `
                -SshClient $script:FakeSshClient `
                -Installed (New-Installed)

            Should -Invoke Remove-VmManifest -Times 1 -Exactly -ParameterFilter {
                $Path -eq '/var/lib/infra-provisioner/manifests/dotnetSdk-10.0.100.json'
            }
        }

        It 'removes every symlink listed in a multi-symlink manifest' {
            # Defensive: the install step only ever writes one symlink for
            # dotnet today, but the manifest schema is general and a
            # future change (e.g. an extra `dotnet-watch` link) must be
            # walked the same way the JDK provider walks its multi-link
            # set.
            $multi = New-Manifest -OwnedSymlinks @(
                @{ path = '/usr/local/bin/dotnet';       target = '/opt/dotnet-10.0.100/dotnet'       },
                @{ path = '/usr/local/bin/dotnet-watch'; target = '/opt/dotnet-10.0.100/dotnet-watch' }
            )
            Mock Read-VmManifest { $multi }

            Uninstall-DotnetSdkVersion `
                -SshClient $script:FakeSshClient `
                -Installed (New-Installed)

            Should -Invoke Remove-VmSymlink -Times 2 -Exactly
            foreach ($p in @('/usr/local/bin/dotnet','/usr/local/bin/dotnet-watch')) {
                Should -Invoke Remove-VmSymlink -ParameterFilter { $Path -eq $p }
            }
        }
    }

    # ----------------------------------------------------------------------
    Context 'ordering and crash safety' {
    # ----------------------------------------------------------------------

        It 'tears down in order: processes -> symlinks -> profile.d -> dirs -> manifest' {
            # Manifest LAST so a crash mid-uninstall leaves the manifest
            # claiming ownership of whatever wreckage remains, and the
            # next reconciler run can replay the whole teardown.
            $script:callOrder = New-Object System.Collections.Generic.List[string]
            Mock Stop-VmProcessesUsingPath { $script:callOrder.Add('stop')      }
            Mock Remove-VmSymlink          { $script:callOrder.Add('symlink')   }
            Mock Remove-VmProfileDScript   { $script:callOrder.Add('profile.d') }
            Mock Remove-VmDirectory        { $script:callOrder.Add('dir')       }
            Mock Remove-VmManifest         { $script:callOrder.Add('manifest')  }

            Uninstall-DotnetSdkVersion `
                -SshClient $script:FakeSshClient `
                -Installed (New-Installed)

            $script:callOrder[0]                            | Should -Be 'stop'
            $script:callOrder[$script:callOrder.Count - 2]  | Should -Be 'dir'
            $script:callOrder[$script:callOrder.Count - 1]  | Should -Be 'manifest'

            $stopIdx     = $script:callOrder.IndexOf('stop')
            $firstSym    = $script:callOrder.IndexOf('symlink')
            $profIdx     = $script:callOrder.IndexOf('profile.d')
            $dirIdx      = $script:callOrder.IndexOf('dir')

            ($firstSym -gt $stopIdx)  | Should -BeTrue
            ($profIdx  -gt $firstSym) | Should -BeTrue
            ($dirIdx   -gt $profIdx)  | Should -BeTrue
        }

        It 'swallows a StillAlive throw from Stop-VmProcessesUsingPath and keeps tearing down' {
            # See the function header: the orchestrator's transactional
            # boundary is per-provider, not per-path. Remove-VmDirectory
            # is the real authority on whether the directory can be
            # freed - aborting here would leave symlinks and profile.d
            # behind for no benefit.
            Mock Stop-VmProcessesUsingPath {
                throw 'Stop-VmProcessesUsingPath: 1 process(es) still hold ''/opt/dotnet-10.0.100'' ...'
            }

            { Uninstall-DotnetSdkVersion `
                -SshClient $script:FakeSshClient `
                -Installed (New-Installed) } | Should -Not -Throw

            Should -Invoke Remove-VmSymlink        -Times 1 -Exactly
            Should -Invoke Remove-VmProfileDScript -Times 1 -Exactly
            Should -Invoke Remove-VmDirectory      -Times 1 -Exactly
            Should -Invoke Remove-VmManifest       -Times 1 -Exactly
        }

        It 'does NOT remove the manifest when Remove-VmDirectory throws' {
            # The manifest is the recovery anchor - removing it after a
            # partially failed dir teardown would orphan whatever rm
            # left behind, and the next run would have nothing to
            # replay against.
            Mock Remove-VmDirectory { throw 'rm failed: device busy' }

            { Uninstall-DotnetSdkVersion `
                -SshClient $script:FakeSshClient `
                -Installed (New-Installed) } |
                Should -Throw -ExpectedMessage '*device busy*'

            Should -Not -Invoke Remove-VmManifest
        }

        It 'propagates a Read-VmManifest failure without touching the VM further' {
            # An Installed record was produced FROM a manifest by
            # Get-InstalledVersions; if the manifest is gone by the
            # time uninstall runs, that is concurrent mutation - surface
            # it rather than guess at what to clean up.
            Mock Read-VmManifest { throw 'Read-VmManifest: ... not found' }

            { Uninstall-DotnetSdkVersion `
                -SshClient $script:FakeSshClient `
                -Installed (New-Installed) } |
                Should -Throw -ExpectedMessage '*not found*'

            Should -Not -Invoke Stop-VmProcessesUsingPath
            Should -Not -Invoke Remove-VmSymlink
            Should -Not -Invoke Remove-VmProfileDScript
            Should -Not -Invoke Remove-VmDirectory
            Should -Not -Invoke Remove-VmManifest
        }
    }
}
