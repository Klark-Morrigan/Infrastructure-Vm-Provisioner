BeforeAll {
    function Invoke-SshClientCommand { param($SshClient, $Command) }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\reconciler\Read-VmManifest.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\reconciler\Get-VmManifestsByProvider.ps1"

    $script:FakeSshClient = [PSCustomObject]@{ }
    $script:StorePath     = '/var/lib/infra-provisioner/manifests'

    function New-ManifestJson {
        param([string]$Provider, [string]$Version)
        @"
{
  "schemaVersion": 1,
  "provider": "$Provider",
  "version": "$Version",
  "ownedPaths": ["/opt/$Provider-$Version"],
  "ownedSymlinks": [],
  "ownedProfileScripts": [],
  "children": []
}
"@
    }
}

Describe 'Get-VmManifestsByProvider' {

    Context 'happy path' {
        It 'parses two valid manifests and attaches _manifestPath to each' {
            $file1 = "$script:StorePath/javaDevKit-21.0.5.json"
            $file2 = "$script:StorePath/javaDevKit-21.0.6.json"

            Mock Invoke-SshClientCommand -ParameterFilter { $Command -like 'ls -1 *' } {
                [PSCustomObject]@{
                    ExitStatus = 0
                    Output     = "$file1`n$file2`n"
                    Error      = ''
                }
            }
            Mock Invoke-SshClientCommand -ParameterFilter { $Command -like "sudo cat -- '$file1'" } {
                [PSCustomObject]@{ ExitStatus = 0; Output = (New-ManifestJson 'javaDevKit' '21.0.5'); Error = '' }
            }
            Mock Invoke-SshClientCommand -ParameterFilter { $Command -like "sudo cat -- '$file2'" } {
                [PSCustomObject]@{ ExitStatus = 0; Output = (New-ManifestJson 'javaDevKit' '21.0.6'); Error = '' }
            }

            $result = Get-VmManifestsByProvider -SshClient $script:FakeSshClient -Provider 'javaDevKit'

            $result.Count           | Should -Be 2
            $result[0].version      | Should -Be '21.0.5'
            $result[0]._manifestPath| Should -Be $file1
            $result[1].version      | Should -Be '21.0.6'
            $result[1]._manifestPath| Should -Be $file2
        }

        It 'scopes the ls glob to the provider prefix' {
            Mock Invoke-SshClientCommand -ParameterFilter { $Command -like 'ls -1 *' } {
                [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
            }

            Get-VmManifestsByProvider -SshClient $script:FakeSshClient -Provider 'dotnetSdk' | Out-Null

            Should -Invoke Invoke-SshClientCommand -Times 1 -Exactly -ParameterFilter {
                $Command -eq "ls -1 -- '$script:StorePath/dotnetSdk-*.json'"
            }
        }
    }

    Context 'absent / empty' {
        It 'returns @() when ls reports no such file or directory (store missing)' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{
                    ExitStatus = 2
                    Output     = ''
                    Error      = "ls: cannot access '$script:StorePath/javaDevKit-*.json': No such file or directory"
                }
            }

            $result = Get-VmManifestsByProvider -SshClient $script:FakeSshClient -Provider 'javaDevKit'

            ,$result | Should -BeOfType [System.Array]
            $result.Count | Should -Be 0
        }

        It 'returns @() when ls succeeds with empty output' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
            }

            $result = Get-VmManifestsByProvider -SshClient $script:FakeSshClient -Provider 'javaDevKit'
            $result.Count | Should -Be 0
        }
    }

    Context 'failure modes' {
        It 'rethrows when ls fails for a reason other than missing-path' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{ ExitStatus = 1; Output = ''; Error = 'permission denied' }
            }

            { Get-VmManifestsByProvider -SshClient $script:FakeSshClient -Provider 'javaDevKit' } |
                Should -Throw -ExpectedMessage "*ls failed*permission denied*"
        }

        It 'rejects a Provider with metacharacters' {
            { Get-VmManifestsByProvider -SshClient $script:FakeSshClient -Provider 'java*Kit' } |
                Should -Throw -ExpectedMessage "*must match*"
        }
    }
}
