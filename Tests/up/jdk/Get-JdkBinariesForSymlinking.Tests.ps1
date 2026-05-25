BeforeAll {
    function Invoke-SshClientCommand { param($SshClient, $Command) }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\jdk\Get-JdkBinariesForSymlinking.ps1"

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
