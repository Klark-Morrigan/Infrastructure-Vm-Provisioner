BeforeAll {
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\common\network\Invoke-WslShell.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\common\network\Test-WslRouterReachability.ps1"

    $script:_TmpDir = Join-Path ([IO.Path]::GetTempPath()) "wsl-probe-tests"
    if (-not (Test-Path -LiteralPath $script:_TmpDir)) {
        New-Item -ItemType Directory -Path $script:_TmpDir -Force | Out-Null
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:_TmpDir -Recurse -Force `
                -ErrorAction SilentlyContinue
}

Describe 'Test-WslRouterReachability' {

    BeforeEach {
        $script:_LogPath = Join-Path $script:_TmpDir "probe-$([guid]::NewGuid()).log"
        # Default mock: every probe succeeds. Mock fires in the
        # source file's scope, which `function global:` cannot
        # reach when the source has its own local Invoke-WslShell.
        Mock Invoke-WslShell {
            param([string] $Distro, [string] $Command)
            if ($Command -match '^true$') {
                $global:LASTEXITCODE = 0
                return ''
            }
            if ($Command -match '^ping ') {
                $global:LASTEXITCODE = 0
                return '3 packets transmitted, 3 received, 0% packet loss'
            }
            if ($Command -match '^nc ') {
                $global:LASTEXITCODE = 0
                return 'Connection to 127.0.0.1 2222 port [tcp/*] succeeded!'
            }
            if ($Command -match '^ssh ') {
                # ssh succeeded TCP+banner, failed auth - that is a
                # SUCCESSFUL banner exchange for this probe's purpose.
                $global:LASTEXITCODE = 255
                return 'sshprobe@127.0.0.1: Permission denied (publickey,password).'
            }
            $global:LASTEXITCODE = 0
            return ''
        }
    }

    Context 'happy path' {

        It 'returns IcmpOk + TcpOk + SshBannerOk all true' {
            $result = Test-WslRouterReachability `
                -WslDistro     'Ubuntu-24.04' `
                -TargetAddress '127.0.0.1' `
                -TargetPort    2222 `
                -LogPath       $script:_LogPath

            $result.IcmpOk      | Should -Be $true
            $result.TcpOk       | Should -Be $true
            $result.SshBannerOk | Should -Be $true
        }

        It 'writes a transcript containing each probe section' {
            Test-WslRouterReachability `
                -WslDistro     'Ubuntu-24.04' `
                -TargetAddress '127.0.0.1' `
                -LogPath       $script:_LogPath | Out-Null

            $log = Get-Content -LiteralPath $script:_LogPath -Raw
            $log | Should -Match '=== Test-WslRouterReachability ==='
            $log | Should -Match '--- ping -c 3'
            $log | Should -Match '--- nc '
            $log | Should -Match '--- ssh banner probe'
            $log | Should -Match 'IcmpOk=True; TcpOk=True; SshBannerOk=True'
        }
    }

    Context 'TCP failure' {

        It 'reports TcpOk=$false when nc exits non-zero' {
            Mock Invoke-WslShell {
                param([string] $Distro, [string] $Command)
                if ($Command -match '^true$') { $global:LASTEXITCODE = 0; return '' }
                if ($Command -match '^nc ')   { $global:LASTEXITCODE = 1; return 'nc: connect failed' }
                $global:LASTEXITCODE = 0; return ''
            }

            $result = Test-WslRouterReachability `
                -WslDistro     'Ubuntu-24.04' `
                -TargetAddress '127.0.0.1' `
                -LogPath       $script:_LogPath

            $result.TcpOk | Should -Be $false
        }
    }

    Context 'SSH banner exchange interpretation' {

        It 'treats "Permission denied" as banner OK (sshd was talking)' {
            # default mock returns Permission denied
            $result = Test-WslRouterReachability `
                -WslDistro     'Ubuntu-24.04' `
                -TargetAddress '127.0.0.1' `
                -LogPath       $script:_LogPath

            $result.SshBannerOk | Should -Be $true
        }

        It 'treats "Connection refused" as banner NOT OK' {
            Mock Invoke-WslShell {
                param([string] $Distro, [string] $Command)
                if ($Command -match '^true$') { $global:LASTEXITCODE = 0; return '' }
                if ($Command -match '^ssh ') {
                    $global:LASTEXITCODE = 255
                    return 'ssh: connect to host 127.0.0.1 port 2222: Connection refused'
                }
                $global:LASTEXITCODE = 0; return 'OK'
            }

            $result = Test-WslRouterReachability `
                -WslDistro     'Ubuntu-24.04' `
                -TargetAddress '127.0.0.1' `
                -LogPath       $script:_LogPath

            $result.SshBannerOk | Should -Be $false
        }

        It 'treats "banner exchange" timeout as banner NOT OK' {
            # The classic Ansible failure mode - banner exchange
            # never completed. Probe must report SshBannerOk=$false.
            Mock Invoke-WslShell {
                param([string] $Distro, [string] $Command)
                if ($Command -match '^true$') { $global:LASTEXITCODE = 0; return '' }
                if ($Command -match '^ssh ') {
                    $global:LASTEXITCODE = 255
                    return 'kex_exchange_identification: Connection closed by remote host (banner exchange timeout)'
                }
                $global:LASTEXITCODE = 0; return 'OK'
            }

            $result = Test-WslRouterReachability `
                -WslDistro     'Ubuntu-24.04' `
                -TargetAddress '127.0.0.1' `
                -LogPath       $script:_LogPath

            $result.SshBannerOk | Should -Be $false
        }
    }

    Context 'WSL distro reachability preflight' {

        It 'throws when the WSL distro is not reachable' {
            Mock Invoke-WslShell {
                param([string] $Distro, [string] $Command)
                $global:LASTEXITCODE = 1
                return 'There is no distribution with the supplied name.'
            }

            { Test-WslRouterReachability `
                -WslDistro     'Nonexistent' `
                -TargetAddress '127.0.0.1' `
                -LogPath       $script:_LogPath } |
                Should -Throw -ExpectedMessage "*WSL distro 'Nonexistent' is not reachable*"
        }
    }
}
