BeforeAll {
    function Invoke-SshClientCommand { param($SshClient, $Command) }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\reconciler\Write-VmManifest.ps1"

    $script:FakeSshClient = [PSCustomObject]@{ }
    $script:StorePath     = '/var/lib/infra-provisioner/manifests'

    function New-Manifest {
        [PSCustomObject]@{
            schemaVersion       = 1
            provider            = 'dotnetSdk'
            version             = '10.0.100'
            ownedPaths          = @('/opt/dotnet-10.0.100')
            ownedSymlinks       = @(
                [PSCustomObject]@{
                    path   = '/usr/local/bin/dotnet'
                    target = '/opt/dotnet-10.0.100/dotnet'
                }
            )
            ownedProfileScripts = @('dotnet')
            children            = @()
        }
    }
}

Describe 'Write-VmManifest' {

    BeforeEach {
        Mock Invoke-SshClientCommand {
            [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
        }
    }

    Context 'emitted bash shape' {
        It 'contains mktemp, chown root:root, chmod 0644, and mv to the {provider}-{version}.json target' {
            Write-VmManifest -SshClient $script:FakeSshClient -Manifest (New-Manifest)

            $target = "$script:StorePath/dotnetSdk-10.0.100.json"
            Should -Invoke Invoke-SshClientCommand -Times 1 -Exactly -ParameterFilter {
                $Command -match 'sudo mktemp'              -and
                $Command -match 'sudo chown root:root'     -and
                $Command -match 'sudo chmod 0644'          -and
                $Command -match ([regex]::Escape("sudo mv `"`$TMP`" '$target'"))
            }
        }

        It 'embeds the host-side ConvertTo-Json -Depth 6 output byte-for-byte' {
            $m   = New-Manifest
            # The production function CRLF->LF-normalises the entire
            # emitted script (including the embedded JSON) so the
            # remote bash interpreter sees Unix line endings. Apply
            # the same normalisation to the expected JSON before the
            # byte-for-byte match.
            $expectedJson = (ConvertTo-Json -InputObject $m -Depth 6) -replace "`r`n", "`n"

            Write-VmManifest -SshClient $script:FakeSshClient -Manifest $m

            Should -Invoke Invoke-SshClientCommand -Times 1 -Exactly -ParameterFilter {
                $Command -match [regex]::Escape($expectedJson)
            }
        }

        It 'uses a single-quoted heredoc so embedded $/quotes/backslashes survive' {
            Write-VmManifest -SshClient $script:FakeSshClient -Manifest (New-Manifest)

            Should -Invoke Invoke-SshClientCommand -Times 1 -Exactly -ParameterFilter {
                $Command -match "cat <<'__INFRA_VM_PROVISIONER_MANIFEST__'"
            }
        }
    }

    Context 'validation' {
        It 'throws when manifest is null' {
            { Write-VmManifest -SshClient $script:FakeSshClient -Manifest $null } |
                Should -Throw -ExpectedMessage "*must not be null*"
        }

        It 'throws when provider is missing' {
            $m = [PSCustomObject]@{ schemaVersion = 1; version = '1.0.0' }
            { Write-VmManifest -SshClient $script:FakeSshClient -Manifest $m } |
                Should -Throw -ExpectedMessage "*provider*non-empty*"
        }

        It 'throws when version is missing' {
            $m = [PSCustomObject]@{ schemaVersion = 1; provider = 'x' }
            { Write-VmManifest -SshClient $script:FakeSshClient -Manifest $m } |
                Should -Throw -ExpectedMessage "*version*non-empty*"
        }

        It 'throws when provider has a shell metacharacter' {
            $m = [PSCustomObject]@{ schemaVersion = 1; provider = 'bad*name'; version = '1' }
            { Write-VmManifest -SshClient $script:FakeSshClient -Manifest $m } |
                Should -Throw -ExpectedMessage "*provider*must match*"
        }

        It 'throws when version has a shell metacharacter' {
            $m = [PSCustomObject]@{ schemaVersion = 1; provider = 'p'; version = '1.0$x' }
            { Write-VmManifest -SshClient $script:FakeSshClient -Manifest $m } |
                Should -Throw -ExpectedMessage "*version*must match*"
        }
    }

    Context 'remote failure' {
        It 'surfaces non-zero exit with target path and stderr' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{ ExitStatus = 1; Output = ''; Error = 'disk full' }
            }

            { Write-VmManifest -SshClient $script:FakeSshClient -Manifest (New-Manifest) } |
                Should -Throw -ExpectedMessage "*Write-VmManifest failed*dotnetSdk-10.0.100.json*disk full*"
        }
    }
}
