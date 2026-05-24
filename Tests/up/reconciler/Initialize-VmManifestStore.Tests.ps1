BeforeAll {
    function Invoke-SshClientCommand { param($SshClient, $Command) }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\reconciler\Initialize-VmManifestStore.ps1"

    $script:FakeSshClient = [PSCustomObject]@{ }
    $script:ManifestStorePath = '/var/lib/infra-provisioner/manifests'
}

Describe 'Initialize-VmManifestStore' {

    BeforeEach {
        Mock Invoke-SshClientCommand {
            [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
        }
    }

    It 'emits the documented mkdir + chown + chmod && chain' {
        Initialize-VmManifestStore -SshClient $script:FakeSshClient

        Should -Invoke Invoke-SshClientCommand -Times 1 -Exactly -ParameterFilter {
            $Command -match [regex]::Escape("sudo mkdir -p '$script:ManifestStorePath'") -and
            $Command -match [regex]::Escape("sudo chown root:root '$script:ManifestStorePath'") -and
            $Command -match [regex]::Escape("sudo chmod 0755 '$script:ManifestStorePath'") -and
            $Command -match '&&'
        }
    }

    It 'is idempotent: a re-run against a successful store does not throw' {
        Initialize-VmManifestStore -SshClient $script:FakeSshClient
        { Initialize-VmManifestStore -SshClient $script:FakeSshClient } | Should -Not -Throw
        Should -Invoke Invoke-SshClientCommand -Times 2 -Exactly
    }

    It 'throws when the remote command exits non-zero' {
        Mock Invoke-SshClientCommand {
            [PSCustomObject]@{ ExitStatus = 1; Output = ''; Error = 'permission denied' }
        }

        { Initialize-VmManifestStore -SshClient $script:FakeSshClient } |
            Should -Throw -ExpectedMessage "*Initialize-VmManifestStore failed*permission denied*"
    }
}
