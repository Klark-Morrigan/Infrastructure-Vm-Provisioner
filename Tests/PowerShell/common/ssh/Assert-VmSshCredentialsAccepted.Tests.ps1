BeforeAll {
    # Stub the Infrastructure.HyperV primitive this wrapper delegates to so
    # Pester can Mock it. Test-VmSshCredential owns connect + auth-vs-
    # transient classification (its own coverage lives in
    # Infrastructure-HyperV/Tests/Test-VmSshCredential.Tests.ps1); here we
    # assert only the provisioner-domain wrapper behaviour on top of it.
    function Test-VmSshCredential {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSAvoidUsingPlainTextForPassword', 'Password')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSAvoidUsingUsernameAndPasswordParams', '')]
        param(
            [string] $IpAddress, [string] $Username, [string] $Password,
            [int] $Port = 22, [TimeSpan] $Timeout
        )
        $true
    }

    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\common\ssh\Assert-VmSshCredentialsAccepted.ps1"
}

Describe 'Assert-VmSshCredentialsAccepted' {

    Context 'credentials accepted' {

        It 'returns without throwing when the probe reports accepted' {
            Mock Test-VmSshCredential { $true }

            { Assert-VmSshCredentialsAccepted `
                -IpAddress '192.168.137.11' -Username 'admin' `
                -Password 'p' -VmName 'ubuntu-01-router' } |
                Should -Not -Throw
        }

        It 'forwards the endpoint and credentials to Test-VmSshCredential' {
            Mock Test-VmSshCredential { $true }

            Assert-VmSshCredentialsAccepted `
                -IpAddress '192.168.137.11' -Username 'admin' `
                -Password 'secret' -VmName 'ubuntu-01-router' -Port 2222

            Should -Invoke Test-VmSshCredential -Times 1 -Exactly -ParameterFilter {
                $IpAddress -eq '192.168.137.11' -and
                $Username  -eq 'admin'  -and
                $Password  -eq 'secret' -and
                $Port      -eq 2222
            }
        }
    }

    Context 'credentials rejected' {

        It 'throws a cloud-init-named error when the probe reports rejected' {
            Mock Test-VmSshCredential { $false }

            { Assert-VmSshCredentialsAccepted `
                -IpAddress '192.168.137.11' -Username 'admin' `
                -Password 'p' -VmName 'ubuntu-01-router' } |
                Should -Throw -ExpectedMessage '*cloud-init most likely failed to create the account*'
        }

        It 'names the VM and the rejected user in the message' {
            Mock Test-VmSshCredential { $false }

            { Assert-VmSshCredentialsAccepted `
                -IpAddress '192.168.137.11' -Username 'admin' `
                -Password 'p' -VmName 'ubuntu-01-router' } |
                Should -Throw -ExpectedMessage "*'ubuntu-01-router'*'admin'*"
        }

        It 'points at the console log when ConsoleLogPath is supplied' {
            Mock Test-VmSshCredential { $false }

            { Assert-VmSshCredentialsAccepted `
                -IpAddress '192.168.137.11' -Username 'admin' `
                -Password 'p' -VmName 'ubuntu-01-router' `
                -ConsoleLogPath 'C:\diag\console.log' } |
                Should -Throw -ExpectedMessage '*C:\diag\console.log*'
        }
    }

    Context 'transient / unreachable failures' {

        It 'lets a transient probe error propagate unchanged (no cloud-init annotation)' {
            # Test-VmSshCredential rethrows timeout/refused/KEX failures; the
            # wrapper must not re-wrap them with the misleading cloud-init
            # wording.
            Mock Test-VmSshCredential { throw 'Connection timed out while opening socket' }

            $threw = $null
            try {
                Assert-VmSshCredentialsAccepted `
                    -IpAddress '192.168.137.11' -Username 'admin' `
                    -Password 'p' -VmName 'ubuntu-01-router'
            } catch { $threw = $_.Exception.Message }

            $threw | Should -Match 'Connection timed out'
            $threw | Should -Not -Match 'cloud-init'
        }
    }
}
