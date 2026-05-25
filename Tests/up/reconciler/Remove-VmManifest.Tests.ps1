BeforeAll {
    function Invoke-SshClientCommand { param($SshClient, $Command) }

    # Remove-VmManifest reuses Assert-VmManifestPath defined in
    # Read-VmManifest.ps1, so both files must be dot-sourced here.
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\reconciler\Read-VmManifest.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\reconciler\Remove-VmManifest.ps1"

    $script:FakeSshClient = [PSCustomObject]@{ }
}

Describe 'Remove-VmManifest' {

    BeforeEach {
        Mock Invoke-SshClientCommand {
            [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
        }
    }

    It "issues 'sudo rm -f -- {path}' on the wire" {
        Remove-VmManifest -SshClient $script:FakeSshClient `
                          -Path '/var/lib/infra-provisioner/manifests/javaDevKit-21.0.5.json'

        Should -Invoke Invoke-SshClientCommand -Times 1 -Exactly -ParameterFilter {
            $Command -eq "sudo rm -f -- '/var/lib/infra-provisioner/manifests/javaDevKit-21.0.5.json'"
        }
    }

    It 'is idempotent: a second call against a missing file does not throw' {
        # `rm -f` returns 0 even when the target is absent, so the mock
        # default (ExitStatus=0) already models the second-run case.
        Remove-VmManifest -SshClient $script:FakeSshClient -Path '/var/lib/infra-provisioner/manifests/x.json'
        { Remove-VmManifest -SshClient $script:FakeSshClient -Path '/var/lib/infra-provisioner/manifests/x.json' } |
            Should -Not -Throw
    }

    It 'throws when the remote command exits non-zero' {
        Mock Invoke-SshClientCommand {
            [PSCustomObject]@{ ExitStatus = 1; Output = ''; Error = 'permission denied' }
        }

        { Remove-VmManifest -SshClient $script:FakeSshClient -Path '/var/lib/infra-provisioner/manifests/x.json' } |
            Should -Throw -ExpectedMessage "*Remove-VmManifest failed*permission denied*"
    }

    Context 'host-side path validation (shared with Read-VmManifest)' {
        It 'rejects a relative path' {
            { Remove-VmManifest -SshClient $script:FakeSshClient -Path 'rel.json' } |
                Should -Throw -ExpectedMessage "*absolute*"
            Should -Invoke Invoke-SshClientCommand -Times 0 -Exactly
        }

        It "rejects a path with a single quote" {
            { Remove-VmManifest -SshClient $script:FakeSshClient -Path "/var/lib/x'.json" } |
                Should -Throw -ExpectedMessage "*single quote*"
            Should -Invoke Invoke-SshClientCommand -Times 0 -Exactly
        }
    }
}
