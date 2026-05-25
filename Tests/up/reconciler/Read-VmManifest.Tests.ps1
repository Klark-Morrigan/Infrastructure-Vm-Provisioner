BeforeAll {
    function Invoke-SshClientCommand { param($SshClient, $Command) }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\reconciler\Read-VmManifest.ps1"

    $script:FakeSshClient = [PSCustomObject]@{ }

    $script:ValidManifestJson = @'
{
  "schemaVersion": 1,
  "provider": "javaDevKit",
  "version": "21.0.5",
  "ownedPaths": ["/opt/jdk-temurin-21.0.5"],
  "ownedSymlinks": [{ "path": "/usr/local/bin/java",
                      "target": "/opt/jdk-temurin-21.0.5/bin/java" }],
  "ownedProfileScripts": ["jdk"],
  "children": []
}
'@
}

Describe 'Read-VmManifest' {

    Context 'happy path' {
        It 'returns a PSCustomObject with the schema fields' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{ ExitStatus = 0; Output = $script:ValidManifestJson; Error = '' }
            }

            $m = Read-VmManifest -SshClient $script:FakeSshClient `
                                 -Path '/var/lib/infra-provisioner/manifests/javaDevKit-21.0.5.json'

            $m.schemaVersion       | Should -Be 1
            $m.provider            | Should -Be 'javaDevKit'
            $m.version             | Should -Be '21.0.5'
            $m.ownedPaths[0]       | Should -Be '/opt/jdk-temurin-21.0.5'
            $m.ownedSymlinks[0].path | Should -Be '/usr/local/bin/java'
        }

        It "issues 'sudo cat -- {path}' on the wire" {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{ ExitStatus = 0; Output = $script:ValidManifestJson; Error = '' }
            }

            Read-VmManifest -SshClient $script:FakeSshClient `
                            -Path '/var/lib/infra-provisioner/manifests/javaDevKit-21.0.5.json' | Out-Null

            Should -Invoke Invoke-SshClientCommand -Times 1 -Exactly -ParameterFilter {
                $Command -eq "sudo cat -- '/var/lib/infra-provisioner/manifests/javaDevKit-21.0.5.json'"
            }
        }
    }

    Context 'failure modes' {
        It 'throws when ssh exit is non-zero (file missing)' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{ ExitStatus = 1; Output = ''; Error = 'cat: No such file' }
            }

            { Read-VmManifest -SshClient $script:FakeSshClient -Path '/var/lib/infra-provisioner/manifests/x.json' } |
                Should -Throw -ExpectedMessage "*failed to read*No such file*"
        }

        It 'throws when body is malformed JSON' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{ ExitStatus = 0; Output = 'not json {{{'; Error = '' }
            }

            { Read-VmManifest -SshClient $script:FakeSshClient -Path '/var/lib/infra-provisioner/manifests/x.json' } |
                Should -Throw -ExpectedMessage "*not valid JSON*"
        }

        It 'throws when schemaVersion is missing' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{ ExitStatus = 0; Output = '{ "provider": "x", "version": "1" }'; Error = '' }
            }

            { Read-VmManifest -SshClient $script:FakeSshClient -Path '/var/lib/infra-provisioner/manifests/x.json' } |
                Should -Throw -ExpectedMessage "*missing required 'schemaVersion'*"
        }

        It 'throws when schemaVersion is not 1' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{ ExitStatus = 0; Output = '{ "schemaVersion": 2 }'; Error = '' }
            }

            { Read-VmManifest -SshClient $script:FakeSshClient -Path '/var/lib/infra-provisioner/manifests/x.json' } |
                Should -Throw -ExpectedMessage "*unsupported schemaVersion '2'*"
        }
    }

    Context 'host-side path validation (before SSH)' {
        BeforeEach {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{ ExitStatus = 0; Output = $script:ValidManifestJson; Error = '' }
            }
        }

        It 'rejects a relative path' {
            { Read-VmManifest -SshClient $script:FakeSshClient -Path 'relative/path.json' } |
                Should -Throw -ExpectedMessage "*absolute*"
            Should -Invoke Invoke-SshClientCommand -Times 0 -Exactly
        }

        It "rejects a path with a single quote" {
            { Read-VmManifest -SshClient $script:FakeSshClient -Path "/var/lib/x'.json" } |
                Should -Throw -ExpectedMessage "*single quote*"
            Should -Invoke Invoke-SshClientCommand -Times 0 -Exactly
        }

        It 'rejects a path with a .. segment' {
            { Read-VmManifest -SshClient $script:FakeSshClient -Path '/var/lib/../etc/passwd' } |
                Should -Throw -ExpectedMessage "*'..' segment*"
            Should -Invoke Invoke-SshClientCommand -Times 0 -Exactly
        }
    }
}
