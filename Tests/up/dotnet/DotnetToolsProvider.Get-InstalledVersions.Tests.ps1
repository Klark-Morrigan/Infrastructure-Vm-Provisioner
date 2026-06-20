BeforeAll {
    # Stub the helper the SUT calls into. Tests mock its return value to
    # drive each scenario; the real implementation is exercised by
    # Get-VmManifestsByProvider.Tests.ps1.
    function Get-VmManifestsByProvider { param($SshClient, $Provider) }

    # ConvertTo-Array ships in Common.PowerShell in production. The
    # SUT uses it to keep the manifest list array-shaped.
    function ConvertTo-Array {
        param($InputObject)
        if ($null -eq $InputObject) { return ,@() }
        return ,@($InputObject)
    }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\dotnet\DotnetToolsProvider.Get-InstalledVersions.ps1"

    $script:FakeSshClient = [PSCustomObject]@{ }

    # Build a manifest via ConvertFrom-Json so PSObject.Properties
    # behaviour matches what Read-VmManifest returns in production.
    function New-Manifest {
        param(
            [string]   $Id,
            [string]   $Version,
            [string[]] $OwnedPaths,
            [object[]] $Symlinks = @(),
            [string]   $ManifestPath
        )

        $obj = [PSCustomObject]@{
            schemaVersion       = 1
            provider            = 'dotnetTools'
            id                  = $Id
            version             = $Version
            ownedPaths          = $OwnedPaths
            ownedSymlinks       = @(
                $Symlinks | ForEach-Object {
                    [PSCustomObject]@{ path = $_.path; target = $_.target }
                }
            )
            parentProvider      = 'dotnetSdk'
        }
        Add-Member `
            -InputObject $obj `
            -MemberType  NoteProperty `
            -Name        '_manifestPath' `
            -Value       $ManifestPath `
            -Force
        return $obj
    }
}

Describe 'Get-DotnetToolsInstalledVersions' {

    # ----------------------------------------------------------------------
    Context 'no manifests' {
    # ----------------------------------------------------------------------

        It 'returns @() when the helper yields no manifests' {
            Mock Get-VmManifestsByProvider { }

            $result = Get-DotnetToolsInstalledVersions -SshClient $script:FakeSshClient

            ,$result -is [array] | Should -BeTrue
            @($result).Count     | Should -Be 0
        }

        It 'queries the helper scoped to the dotnetTools provider' {
            Mock Get-VmManifestsByProvider { }

            Get-DotnetToolsInstalledVersions -SshClient $script:FakeSshClient | Out-Null

            Should -Invoke Get-VmManifestsByProvider -Times 1 -Exactly `
                -ParameterFilter { $Provider -eq 'dotnetTools' }
        }
    }

    # ----------------------------------------------------------------------
    Context 'happy path' {
    # ----------------------------------------------------------------------

        It 'projects one manifest into one Installed record with composite Version' {
            $manifestPath = '/var/lib/infra-provisioner/manifests/dotnetTools-dotnet-reportgenerator-globaltool-5.4.4.json'
            Mock Get-VmManifestsByProvider {
                New-Manifest `
                    -Id           'dotnet-reportgenerator-globaltool' `
                    -Version      '5.4.4' `
                    -OwnedPaths   '/usr/local/share/dotnet/tools/.store/dotnet-reportgenerator-globaltool/5.4.4' `
                    -Symlinks     @(@{ path='/usr/local/bin/reportgenerator'; target='/usr/local/share/dotnet/tools/reportgenerator' }) `
                    -ManifestPath $manifestPath
            }

            $result = Get-DotnetToolsInstalledVersions -SshClient $script:FakeSshClient

            @($result).Count        | Should -Be 1
            $result[0].Provider     | Should -Be 'dotnetTools'
            $result[0].Version      | Should -Be 'dotnet-reportgenerator-globaltool@5.4.4'
            $result[0].Id           | Should -Be 'dotnet-reportgenerator-globaltool'
            $result[0].RawVersion   | Should -Be '5.4.4'
            $result[0].InstallPath  | Should -Be '/usr/local/share/dotnet/tools/.store/dotnet-reportgenerator-globaltool/5.4.4'
            $result[0].ManifestPath | Should -Be $manifestPath
            @($result[0].Symlinks).Count | Should -Be 1
            @($result[0].Symlinks)[0].path | Should -Be '/usr/local/bin/reportgenerator'
        }

        It 'projects two manifests into two records preserving order' {
            $p1 = '/var/lib/infra-provisioner/manifests/dotnetTools-a-1.0.0.json'
            $p2 = '/var/lib/infra-provisioner/manifests/dotnetTools-b-2.0.0.json'
            Mock Get-VmManifestsByProvider {
                New-Manifest -Id 'a' -Version '1.0.0' `
                    -OwnedPaths '/usr/local/share/dotnet/tools/.store/a/1.0.0' `
                    -ManifestPath $p1
                New-Manifest -Id 'b' -Version '2.0.0' `
                    -OwnedPaths '/usr/local/share/dotnet/tools/.store/b/2.0.0' `
                    -ManifestPath $p2
            }

            $result = Get-DotnetToolsInstalledVersions -SshClient $script:FakeSshClient

            @($result).Count        | Should -Be 2
            $result[0].Id           | Should -Be 'a'
            $result[0].Version      | Should -Be 'a@1.0.0'
            $result[1].Id           | Should -Be 'b'
            $result[1].Version      | Should -Be 'b@2.0.0'
        }

        It 'defaults Symlinks to @() when ownedSymlinks is missing' {
            # Belt-and-braces: Install-Version always writes the field,
            # but Uninstall-Version must tolerate iterating an empty
            # list rather than choke on null.
            Mock Get-VmManifestsByProvider {
                $m = New-Manifest -Id 'a' -Version '1.0.0' `
                                  -OwnedPaths '/x' `
                                  -ManifestPath '/p.json'
                # Strip ownedSymlinks to simulate a hand-edited manifest.
                $m.PSObject.Properties.Remove('ownedSymlinks')
                $m
            }

            $result = Get-DotnetToolsInstalledVersions -SshClient $script:FakeSshClient

            @($result).Count           | Should -Be 1
            ,$result[0].Symlinks -is [array] | Should -BeTrue
            @($result[0].Symlinks).Count     | Should -Be 0
        }
    }

    # ----------------------------------------------------------------------
    Context 'malformed manifests' {
    # ----------------------------------------------------------------------

        It 'warns and skips a manifest missing the id field, returning the others' {
            $goodPath = '/var/lib/infra-provisioner/manifests/dotnetTools-good.json'
            $badPath  = '/var/lib/infra-provisioner/manifests/dotnetTools-bad.json'
            Mock Get-VmManifestsByProvider {
                New-Manifest -Id '' -Version '1.0.0' -OwnedPaths '/x' -ManifestPath $badPath
                New-Manifest -Id 'good' -Version '1.0.0' -OwnedPaths '/y' -ManifestPath $goodPath
            }

            $result = Get-DotnetToolsInstalledVersions `
                        -SshClient $script:FakeSshClient `
                        -WarningAction SilentlyContinue

            @($result).Count        | Should -Be 1
            $result[0].Id           | Should -Be 'good'
        }

        It 'warns and skips a manifest with empty ownedPaths' {
            $badPath = '/var/lib/infra-provisioner/manifests/dotnetTools-empty.json'
            Mock Get-VmManifestsByProvider {
                New-Manifest -Id 'a' -Version '1.0.0' -OwnedPaths @() -ManifestPath $badPath
            }

            $result = Get-DotnetToolsInstalledVersions `
                        -SshClient $script:FakeSshClient `
                        -WarningAction SilentlyContinue

            @($result).Count | Should -Be 0
        }
    }
}
