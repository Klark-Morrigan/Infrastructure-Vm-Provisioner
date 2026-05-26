BeforeAll {
    # Stub every primitive the SUT calls. The real implementations live
    # in Infrastructure.HyperV (Expand-VmTarball, Set-VmProfileDScript,
    # New-VmSymlink) and in the reconciler folder (Write-VmManifest);
    # each is exercised by its own test suite, so this file only
    # verifies orchestration (order, arg flow, manifest shape,
    # fail-fast on extract / symlink failure).
    function Expand-VmTarball     { param($SshClient, $Server, $TarballPath, $Destination, $StripComponents) }
    function Set-VmProfileDScript { param($SshClient, $Name, $Content) }
    function New-VmSymlink        { param($SshClient, $Path, $Target) }
    function Write-VmManifest     { param($SshClient, $Manifest) }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\dotnet\DotnetSdkProvider.Install-Version.ps1"

    $script:FakeSshClient = [PSCustomObject]@{ }
    $script:FakeServer    = [PSCustomObject]@{ BaseUrl = 'http://192.168.1.1:8745' }

    function New-DotnetSpec {
        [PSCustomObject]@{
            Provider         = 'dotnetSdk'
            Channel          = '10.0'
            RequestedVersion = '10.0'
            Version          = '10.0.100'
            TarballPath      = 'C:\cache\dotnet-sdk-10.0.100-linux-x64.tar.gz'
        }
    }
}

Describe 'Install-DotnetSdkVersion' {

    BeforeEach {
        Mock Expand-VmTarball     { }
        Mock Set-VmProfileDScript { }
        Mock New-VmSymlink        { }
        Mock Write-VmManifest     { }
    }

    # ----------------------------------------------------------------------
    Context 'happy path - primitive wiring' {
    # ----------------------------------------------------------------------

        It 'extracts the tarball into /opt/dotnet-{resolvedVersion} with strip=0' {
            Install-DotnetSdkVersion `
                -SshClient $script:FakeSshClient `
                -Server    $script:FakeServer `
                -Spec      (New-DotnetSpec)

            Should -Invoke Expand-VmTarball -Times 1 -Exactly -ParameterFilter {
                $TarballPath     -eq 'C:\cache\dotnet-sdk-10.0.100-linux-x64.tar.gz' -and
                $Destination     -eq '/opt/dotnet-10.0.100'                          -and
                $StripComponents -eq 0
            }
        }

        It 'writes /etc/profile.d/dotnet.sh with DOTNET_ROOT, PATH and telemetry opt-out' {
            Install-DotnetSdkVersion `
                -SshClient $script:FakeSshClient `
                -Server    $script:FakeServer `
                -Spec      (New-DotnetSpec)

            Should -Invoke Set-VmProfileDScript -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'dotnet' -and
                $Content -match 'export DOTNET_ROOT=/opt/dotnet-10\.0\.100' -and
                $Content -match 'export PATH="\$DOTNET_ROOT:\$PATH"' -and
                $Content -match 'export DOTNET_CLI_TELEMETRY_OPTOUT=1'
            }
        }

        It 'creates a single /usr/local/bin/dotnet symlink to the install dir driver' {
            Install-DotnetSdkVersion `
                -SshClient $script:FakeSshClient `
                -Server    $script:FakeServer `
                -Spec      (New-DotnetSpec)

            Should -Invoke New-VmSymlink -Times 1 -Exactly -ParameterFilter {
                $Path   -eq '/usr/local/bin/dotnet' -and
                $Target -eq '/opt/dotnet-10.0.100/dotnet'
            }
        }

        It 'writes a manifest carrying ownedPaths, ownedSymlinks, ownedProfileScripts' {
            Install-DotnetSdkVersion `
                -SshClient $script:FakeSshClient `
                -Server    $script:FakeServer `
                -Spec      (New-DotnetSpec)

            Should -Invoke Write-VmManifest -Times 1 -Exactly -ParameterFilter {
                $Manifest.schemaVersion             -eq 1               -and
                $Manifest.provider                  -eq 'dotnetSdk'     -and
                $Manifest.version                   -eq '10.0.100'      -and
                @($Manifest.ownedPaths)[0]          -eq '/opt/dotnet-10.0.100' -and
                @($Manifest.ownedProfileScripts)[0] -eq 'dotnet'        -and
                @($Manifest.ownedSymlinks).Count    -eq 1               -and
                @($Manifest.children).Count         -eq 0
            }
        }

        It 'records the created symlink under ownedSymlinks (path + target)' {
            Install-DotnetSdkVersion `
                -SshClient $script:FakeSshClient `
                -Server    $script:FakeServer `
                -Spec      (New-DotnetSpec)

            Should -Invoke Write-VmManifest -ParameterFilter {
                $sym = @($Manifest.ownedSymlinks)[0]
                $sym.path   -eq '/usr/local/bin/dotnet' -and
                $sym.target -eq '/opt/dotnet-10.0.100/dotnet'
            }
        }
    }

    # ----------------------------------------------------------------------
    Context 'ordering and crash safety' {
    # ----------------------------------------------------------------------

        It 'writes the manifest LAST (after extract, profile.d, and symlink)' {
            # A manifest written before the side effects would lie about
            # ownership if the install crashes mid-flight; the next run
            # would treat half-installed state as owned and try to clean
            # it up rather than re-running the extract.
            $script:callOrder = New-Object System.Collections.Generic.List[string]
            Mock Expand-VmTarball     { $script:callOrder.Add('extract')   }
            Mock Set-VmProfileDScript { $script:callOrder.Add('profile.d') }
            Mock New-VmSymlink        { $script:callOrder.Add('symlink')   }
            Mock Write-VmManifest     { $script:callOrder.Add('manifest')  }

            Install-DotnetSdkVersion `
                -SshClient $script:FakeSshClient `
                -Server    $script:FakeServer `
                -Spec      (New-DotnetSpec)

            $script:callOrder[0]                           | Should -Be 'extract'
            $script:callOrder[1]                           | Should -Be 'profile.d'
            $script:callOrder[2]                           | Should -Be 'symlink'
            $script:callOrder[$script:callOrder.Count - 1] | Should -Be 'manifest'
        }

        It 'does NOT run anything else when Expand-VmTarball throws' {
            Mock Expand-VmTarball { throw 'extract failed' }

            { Install-DotnetSdkVersion `
                -SshClient $script:FakeSshClient `
                -Server    $script:FakeServer `
                -Spec      (New-DotnetSpec) } |
                Should -Throw -ExpectedMessage '*extract failed*'

            Should -Not -Invoke Set-VmProfileDScript
            Should -Not -Invoke New-VmSymlink
            Should -Not -Invoke Write-VmManifest
        }

        It 'does NOT write the manifest when symlink creation throws' {
            # The manifest is the recovery anchor; writing it after a
            # failed symlink run would lie about ownership.
            Mock New-VmSymlink { throw 'symlink failed' }

            { Install-DotnetSdkVersion `
                -SshClient $script:FakeSshClient `
                -Server    $script:FakeServer `
                -Spec      (New-DotnetSpec) } |
                Should -Throw -ExpectedMessage '*symlink failed*'

            Should -Not -Invoke Write-VmManifest
        }
    }
}
