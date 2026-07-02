BeforeAll {
    function Invoke-SshClientCommand { param($SshClient, $Command) }

    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\up\jdk\Get-JdkBinariesForSymlinking.ps1"

    $script:FakeSshClient = [PSCustomObject]@{ }
}

Describe 'Get-JdkBinariesForSymlinking' {

    # ----------------------------------------------------------------------
    Context 'happy path' {
    # ----------------------------------------------------------------------

        It 'lists the install-dir bin over SSH with the deterministic ls form' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{ ExitStatus = 0; Output = "java`n"; Error = '' }
            }

            Get-JdkBinariesForSymlinking `
                -SshClient  $script:FakeSshClient `
                -InstallDir '/opt/jdk-temurin-21.0.6+7' | Out-Null

            Should -Invoke Invoke-SshClientCommand -Times 1 -Exactly -ParameterFilter {
                $Command -eq "ls -1 -- '/opt/jdk-temurin-21.0.6+7/bin'"
            }
        }

        It 'returns one entry per non-empty LF-delimited line, trimmed' {
            Mock Invoke-SshClientCommand {
                # Embedded trailing CRs simulate the SSH transport's TTY
                # behaviour; blank lines must be dropped.
                [PSCustomObject]@{
                    ExitStatus = 0
                    Output     = "java`r`njavac`n`njar`n"
                    Error      = ''
                }
            }

            $names = Get-JdkBinariesForSymlinking `
                -SshClient  $script:FakeSshClient `
                -InstallDir '/opt/jdk-temurin-21'

            ,$names -is [array] | Should -BeTrue
            @($names).Count     | Should -Be 3
            $names[0]           | Should -Be 'java'
            $names[1]           | Should -Be 'javac'
            $names[2]           | Should -Be 'jar'
        }

        It 'preserves array shape for a single-entry listing' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{ ExitStatus = 0; Output = "java`n"; Error = '' }
            }

            $names = Get-JdkBinariesForSymlinking `
                -SshClient  $script:FakeSshClient `
                -InstallDir '/opt/jdk-temurin-21'

            ,$names -is [array] | Should -BeTrue
            @($names).Count     | Should -Be 1
            $names[0]           | Should -Be 'java'
        }
    }

    # ----------------------------------------------------------------------
    Context 'failure modes' {
    # ----------------------------------------------------------------------

        It 'throws naming the install dir when ls exits non-zero' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{
                    ExitStatus = 2
                    Output     = ''
                    Error      = 'ls: cannot access ...'
                }
            }

            { Get-JdkBinariesForSymlinking `
                -SshClient  $script:FakeSshClient `
                -InstallDir '/opt/jdk-temurin-21.0.6+7' } |
                Should -Throw -ExpectedMessage "*/opt/jdk-temurin-21.0.6+7/bin*"
        }

        It 'augments the throw with the install-dir mode + owner' {
            # The function issues two SSH calls on the failure path:
            # the ls (returns non-zero) and a stat probe whose output
            # is folded into the error message. Two-call mock returns
            # the ls failure first, the stat success second.
            $script:callIdx = 0
            Mock Invoke-SshClientCommand {
                $script:callIdx++
                if ($script:callIdx -eq 1) {
                    [PSCustomObject]@{
                        ExitStatus = 2; Output = ''
                        Error = 'ls: Permission denied'
                    }
                } else {
                    [PSCustomObject]@{
                        ExitStatus = 0
                        Output = 'mode=700 owner=root:root'
                        Error = ''
                    }
                }
            }

            { Get-JdkBinariesForSymlinking `
                -SshClient  $script:FakeSshClient `
                -InstallDir '/opt/jdk-temurin-21' } |
                Should -Throw -ExpectedMessage '*install dir: mode=700 owner=root:root*'

            # And the stat probe was actually issued (regression guard
            # against a future refactor that drops the second call).
            Should -Invoke Invoke-SshClientCommand `
                -ParameterFilter { $Command -match 'stat -c .*--\s.*jdk-temurin-21' } `
                -Times 1 -Exactly
        }

        It 'falls back to a stat-probe-failed note when the stat itself fails' {
            $script:callIdx = 0
            Mock Invoke-SshClientCommand {
                $script:callIdx++
                if ($script:callIdx -eq 1) {
                    [PSCustomObject]@{
                        ExitStatus = 2; Output = ''
                        Error = 'ls: Permission denied'
                    }
                } else {
                    [PSCustomObject]@{
                        ExitStatus = 1; Output = ''
                        Error = 'sudo: no tty'
                    }
                }
            }

            { Get-JdkBinariesForSymlinking `
                -SshClient  $script:FakeSshClient `
                -InstallDir '/opt/jdk-temurin-21' } |
                Should -Throw -ExpectedMessage '*stat probe failed (exit 1)*sudo: no tty*'
        }

        It 'throws when the listing is empty (corrupt extract)' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{ ExitStatus = 0; Output = "`n"; Error = '' }
            }

            { Get-JdkBinariesForSymlinking `
                -SshClient  $script:FakeSshClient `
                -InstallDir '/opt/jdk-temurin-21' } |
                Should -Throw -ExpectedMessage '*no entries*'
        }
    }
}
