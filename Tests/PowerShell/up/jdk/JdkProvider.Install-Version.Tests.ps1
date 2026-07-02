BeforeAll {
    # Stub every primitive and helper the SUT calls into. The real
    # implementations live in Infrastructure.HyperV (Expand-VmTarball,
    # Set-VmProfileDScript, New-VmSymlink), in the reconciler folder
    # (Write-VmManifest), and in Get-JdkBinariesForSymlinking.ps1 next
    # to the SUT - each is exercised by its own test suite, so this
    # file only verifies orchestration (order, arg flow, manifest
    # shape, fail-fast on extract / symlink failure).
    function Expand-VmTarball             { param($SshClient, $Server, $TarballPath, $Destination, $StripComponents) }
    function Set-VmProfileDScript         { param($SshClient, $Name, $Content) }
    function New-VmSymlink                { param($SshClient, $Path, $Target) }
    function Write-VmManifest             { param($SshClient, $Manifest) }
    function Get-JdkBinariesForSymlinking { param($SshClient, $InstallDir) }

    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\up\jdk\JdkProvider.Install-Version.ps1"

    $script:FakeSshClient = [PSCustomObject]@{ }
    $script:FakeServer    = [PSCustomObject]@{ BaseUrl = 'http://192.168.1.1:8745' }

    function New-JdkSpec {
        [PSCustomObject]@{
            Provider = 'javaDevKit'
            Vendor   = 'temurin'
            Version  = '21'
        }
    }
}

Describe 'Install-JdkVersion' {

    BeforeEach {
        Mock Expand-VmTarball             { }
        Mock Set-VmProfileDScript         { }
        Mock New-VmSymlink                { }
        Mock Write-VmManifest             { }
        Mock Get-JdkBinariesForSymlinking { ,@('java', 'javac', 'jar') }
    }

    # ----------------------------------------------------------------------
    Context 'happy path - primitive wiring' {
    # ----------------------------------------------------------------------

        It 'extracts the tarball into /opt/jdk-{vendor}-{resolvedVersion} with strip=1' {
            Install-JdkVersion `
                -SshClient       $script:FakeSshClient `
                -Server          $script:FakeServer `
                -Spec            (New-JdkSpec) `
                -TarballPath     'C:\cache\jdk-temurin-21-linux-x64.tar.gz' `
                -ResolvedVersion '21.0.6+7'

            Should -Invoke Expand-VmTarball -Times 1 -Exactly -ParameterFilter {
                $TarballPath     -eq 'C:\cache\jdk-temurin-21-linux-x64.tar.gz' -and
                $Destination     -eq '/opt/jdk-temurin-21.0.6+7'              -and
                $StripComponents -eq 1
            }
        }

        It 'writes /etc/profile.d/jdk.sh with JAVA_HOME and PATH wiring' {
            Install-JdkVersion `
                -SshClient       $script:FakeSshClient `
                -Server          $script:FakeServer `
                -Spec            (New-JdkSpec) `
                -TarballPath     'C:\cache\x.tar.gz' `
                -ResolvedVersion '21.0.6+7'

            Should -Invoke Set-VmProfileDScript -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'jdk' -and
                $Content -match 'export JAVA_HOME=/opt/jdk-temurin-21\.0\.6\+7' -and
                $Content -match 'export PATH="\$JAVA_HOME/bin:\$PATH"'
            }
        }

        It 'enumerates the bin/ dir via Get-JdkBinariesForSymlinking' {
            Install-JdkVersion `
                -SshClient       $script:FakeSshClient `
                -Server          $script:FakeServer `
                -Spec            (New-JdkSpec) `
                -TarballPath     'C:\cache\x.tar.gz' `
                -ResolvedVersion '21.0.6+7'

            Should -Invoke Get-JdkBinariesForSymlinking -Times 1 -Exactly -ParameterFilter {
                $InstallDir -eq '/opt/jdk-temurin-21.0.6+7'
            }
        }

        It 'creates one /usr/local/bin symlink per enumerated binary' {
            Install-JdkVersion `
                -SshClient       $script:FakeSshClient `
                -Server          $script:FakeServer `
                -Spec            (New-JdkSpec) `
                -TarballPath     'C:\cache\x.tar.gz' `
                -ResolvedVersion '21.0.6+7'

            Should -Invoke New-VmSymlink -Times 3 -Exactly
            Should -Invoke New-VmSymlink -ParameterFilter {
                $Path -eq '/usr/local/bin/java' -and
                $Target -eq '/opt/jdk-temurin-21.0.6+7/bin/java'
            }
            Should -Invoke New-VmSymlink -ParameterFilter {
                $Path -eq '/usr/local/bin/javac' -and
                $Target -eq '/opt/jdk-temurin-21.0.6+7/bin/javac'
            }
            Should -Invoke New-VmSymlink -ParameterFilter {
                $Path -eq '/usr/local/bin/jar' -and
                $Target -eq '/opt/jdk-temurin-21.0.6+7/bin/jar'
            }
        }

        It 'writes a manifest carrying ownedPaths, ownedSymlinks, ownedProfileScripts' {
            Install-JdkVersion `
                -SshClient       $script:FakeSshClient `
                -Server          $script:FakeServer `
                -Spec            (New-JdkSpec) `
                -TarballPath     'C:\cache\x.tar.gz' `
                -ResolvedVersion '21.0.6+7'

            Should -Invoke Write-VmManifest -Times 1 -Exactly -ParameterFilter {
                $Manifest.schemaVersion       -eq 1                         -and
                $Manifest.provider            -eq 'javaDevKit'              -and
                $Manifest.version             -eq '21.0.6+7'                -and
                @($Manifest.ownedPaths)[0]    -eq '/opt/jdk-temurin-21.0.6+7' -and
                @($Manifest.ownedProfileScripts)[0] -eq 'jdk'               -and
                @($Manifest.ownedSymlinks).Count -eq 3                      -and
                @($Manifest.children).Count   -eq 0
            }
        }

        It 'records each created symlink under ownedSymlinks (path + target)' {
            Install-JdkVersion `
                -SshClient       $script:FakeSshClient `
                -Server          $script:FakeServer `
                -Spec            (New-JdkSpec) `
                -TarballPath     'C:\cache\x.tar.gz' `
                -ResolvedVersion '21.0.6+7'

            Should -Invoke Write-VmManifest -ParameterFilter {
                $sym = @($Manifest.ownedSymlinks)
                $java = $sym | Where-Object { $_.path -eq '/usr/local/bin/java' }
                $null -ne $java -and
                $java.target -eq '/opt/jdk-temurin-21.0.6+7/bin/java'
            }
        }
    }

    # ----------------------------------------------------------------------
    Context 'ordering and crash safety' {
    # ----------------------------------------------------------------------

        It 'writes the manifest LAST (after extract, profile.d, and symlinks)' {
            # A manifest written before the side effects would lie about
            # ownership if the install crashes mid-flight; the next run
            # would treat half-installed state as owned and try to clean
            # it up rather than re-running the extract.
            $script:callOrder = New-Object System.Collections.Generic.List[string]
            Mock Expand-VmTarball     { $script:callOrder.Add('extract')   }
            Mock Set-VmProfileDScript { $script:callOrder.Add('profile.d') }
            Mock New-VmSymlink        { $script:callOrder.Add('symlink')   }
            Mock Write-VmManifest     { $script:callOrder.Add('manifest')  }

            Install-JdkVersion `
                -SshClient       $script:FakeSshClient `
                -Server          $script:FakeServer `
                -Spec            (New-JdkSpec) `
                -TarballPath     'C:\cache\x.tar.gz' `
                -ResolvedVersion '21.0.6+7'

            $script:callOrder[0]                          | Should -Be 'extract'
            $script:callOrder[1]                          | Should -Be 'profile.d'
            $script:callOrder[$script:callOrder.Count - 1]| Should -Be 'manifest'
            # All symlinks land between profile.d and manifest.
            $script:callOrder[2..($script:callOrder.Count - 2)] |
                ForEach-Object { $_ | Should -Be 'symlink' }
        }

        It 'does NOT run anything else when Expand-VmTarball throws' {
            Mock Expand-VmTarball { throw 'extract failed' }

            { Install-JdkVersion `
                -SshClient       $script:FakeSshClient `
                -Server          $script:FakeServer `
                -Spec            (New-JdkSpec) `
                -TarballPath     'C:\cache\x.tar.gz' `
                -ResolvedVersion '21.0.6+7' } |
                Should -Throw -ExpectedMessage '*extract failed*'

            Should -Not -Invoke Set-VmProfileDScript
            Should -Not -Invoke New-VmSymlink
            Should -Not -Invoke Write-VmManifest
        }

        It 'does NOT write the manifest when symlink creation throws' {
            # The manifest is the recovery anchor; writing it after a
            # partially failed symlink run would lie about ownership.
            Mock New-VmSymlink { throw 'symlink failed' }

            { Install-JdkVersion `
                -SshClient       $script:FakeSshClient `
                -Server          $script:FakeServer `
                -Spec            (New-JdkSpec) `
                -TarballPath     'C:\cache\x.tar.gz' `
                -ResolvedVersion '21.0.6+7' } |
                Should -Throw -ExpectedMessage '*symlink failed*'

            Should -Not -Invoke Write-VmManifest
        }
    }
}
