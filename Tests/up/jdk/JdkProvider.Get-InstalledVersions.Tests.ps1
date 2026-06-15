BeforeAll {
    # Stub the helper the SUT calls into. Tests mock its return value to
    # drive each scenario; the real implementation is exercised by
    # Get-VmManifestsByProvider.Tests.ps1 and not under test here.
    function Get-VmManifestsByProvider { param($SshClient, $Provider) }

    # ConvertTo-Array ships in Common.PowerShell in production. The
    # SUT uses it to keep the manifest list array-shaped without falling
    # into the @()-in-if-expression collapse-to-$null trap. Tests
    # reproduce its minimal contract.
    function ConvertTo-Array {
        param([Parameter(ValueFromPipeline)] $InputObject)
        if ($null -eq $InputObject) { return ,@() }
        return ,@($InputObject)
    }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\jdk\JdkProvider.Get-InstalledVersions.ps1"

    $script:FakeSshClient = [PSCustomObject]@{ }

    # Mirrors the on-VM manifest shape (see plan Step 2). Built via
    # ConvertFrom-Json so PSObject.Properties behaviour matches what
    # the production helper produces from a real ssh `cat` output.
    function New-Manifest {
        param(
            [string]   $Version,
            [string[]] $OwnedPaths,
            [string]   $ManifestPath
        )
        $pathsJson = if ($null -eq $OwnedPaths) {
            'null'
        } elseif ($OwnedPaths.Count -eq 0) {
            '[]'
        } else {
            '[' + (($OwnedPaths | ForEach-Object { "`"$_`"" }) -join ',') + ']'
        }
        $json = @"
{
  "schemaVersion": 1,
  "provider": "javaDevKit",
  "version": "$Version",
  "ownedPaths": $pathsJson,
  "ownedSymlinks": [],
  "ownedProfileScripts": [],
  "children": []
}
"@
        $obj = $json | ConvertFrom-Json
        Add-Member `
            -InputObject $obj `
            -MemberType  NoteProperty `
            -Name        '_manifestPath' `
            -Value       $ManifestPath `
            -Force
        return $obj
    }
}

Describe 'Get-JdkInstalledVersions' {

    # ----------------------------------------------------------------------
    Context 'no manifests' {
    # ----------------------------------------------------------------------

        It 'returns @() when the helper yields no manifests' {
            Mock Get-VmManifestsByProvider { }

            $result = Get-JdkInstalledVersions -SshClient $script:FakeSshClient

            ,$result -is [array] | Should -BeTrue
            @($result).Count     | Should -Be 0
        }

        It 'queries the helper scoped to the javaDevKit provider' {
            Mock Get-VmManifestsByProvider { }

            Get-JdkInstalledVersions -SshClient $script:FakeSshClient | Out-Null

            Should -Invoke Get-VmManifestsByProvider -Times 1 -Exactly `
                -ParameterFilter { $Provider -eq 'javaDevKit' }
        }
    }

    # ----------------------------------------------------------------------
    Context 'happy path' {
    # ----------------------------------------------------------------------

        It 'projects one manifest into one Installed record' {
            $manifestPath = '/var/lib/infra-provisioner/manifests/javaDevKit-21.0.5.json'
            Mock Get-VmManifestsByProvider {
                New-Manifest -Version '21.0.5' `
                             -OwnedPaths '/opt/jdk-temurin-21.0.5' `
                             -ManifestPath $manifestPath
            }

            $result = Get-JdkInstalledVersions -SshClient $script:FakeSshClient

            @($result).Count           | Should -Be 1
            $result[0].Provider        | Should -Be 'javaDevKit'
            $result[0].Version         | Should -Be '21.0.5'
            $result[0].InstallPath     | Should -Be '/opt/jdk-temurin-21.0.5'
            $result[0].ManifestPath    | Should -Be $manifestPath
        }

        It 'projects two manifests into two records preserving order' {
            $p1 = '/var/lib/infra-provisioner/manifests/javaDevKit-21.0.5.json'
            $p2 = '/var/lib/infra-provisioner/manifests/javaDevKit-21.0.6.json'
            Mock Get-VmManifestsByProvider {
                New-Manifest -Version '21.0.5' -OwnedPaths '/opt/jdk-temurin-21.0.5' -ManifestPath $p1
                New-Manifest -Version '21.0.6' -OwnedPaths '/opt/jdk-temurin-21.0.6' -ManifestPath $p2
            }

            $result = Get-JdkInstalledVersions -SshClient $script:FakeSshClient

            @($result).Count        | Should -Be 2
            $result[0].Version      | Should -Be '21.0.5'
            $result[0].ManifestPath | Should -Be $p1
            $result[1].Version      | Should -Be '21.0.6'
            $result[1].ManifestPath | Should -Be $p2
        }
    }

    # ----------------------------------------------------------------------
    Context 'corrupt manifests' {
    # ----------------------------------------------------------------------

        It 'throws naming the manifest path when ownedPaths is missing/null' {
            $manifestPath = '/var/lib/infra-provisioner/manifests/javaDevKit-broken.json'
            Mock Get-VmManifestsByProvider {
                New-Manifest -Version 'broken' `
                             -OwnedPaths $null `
                             -ManifestPath $manifestPath
            }

            { Get-JdkInstalledVersions -SshClient $script:FakeSshClient } |
                Should -Throw -ExpectedMessage "*$manifestPath*ownedPaths*"
        }

        It 'throws naming the manifest path when ownedPaths is empty' {
            $manifestPath = '/var/lib/infra-provisioner/manifests/javaDevKit-empty.json'
            Mock Get-VmManifestsByProvider {
                New-Manifest -Version 'empty' `
                             -OwnedPaths @() `
                             -ManifestPath $manifestPath
            }

            { Get-JdkInstalledVersions -SshClient $script:FakeSshClient } |
                Should -Throw -ExpectedMessage "*$manifestPath*ownedPaths*"
        }
    }
}
