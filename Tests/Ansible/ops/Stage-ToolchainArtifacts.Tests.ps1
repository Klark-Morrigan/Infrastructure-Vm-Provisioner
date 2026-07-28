# PSAvoidOverwritingBuiltInCmdlets is suppressed file-wide: the BeforeAll
# stubs deliberately shadow built-in cmdlets so Pester has a symbol to mock
# and no call reaches the real host or network. This is the test-double seam,
# not accidental shadowing.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidOverwritingBuiltInCmdlets', '',
    Justification = 'Test stubs deliberately shadow built-ins as a Pester mock seam')]
param()

BeforeAll {
    # Stub every cmdlet that touches the network or real filesystem. Stubs are
    # permissive no-ops; individual tests override with Mock. The parameter
    # lists cover the call sites in Stage-ToolchainArtifacts.ps1 (LiteralPath +
    # pipeline input for Set-Content in particular) so a mock ParameterFilter
    # has the named variables to key off.
    function Test-Path         { param($Path, $LiteralPath, $PathType) }
    function New-Item          { param($Path, $ItemType, [switch]$Force) }
    function Get-Content       { param($Path, $LiteralPath, [switch]$Raw) }
    function Get-FileHash      { param($Path, $LiteralPath, $Algorithm) }
    function Invoke-WebRequest { param($Uri, $OutFile, [switch]$UseBasicParsing) }
    function Remove-Item       { param($Path, $LiteralPath, [switch]$Force, $ErrorAction) }
    function Set-Content {
        param(
            [Parameter(ValueFromPipeline = $true)] $InputObject,
            $LiteralPath, $Path, $Value, $Encoding
        )
        # Empty process block: the SUT writes the per-artifact lockfile via a
        # pipeline (`... | Set-Content`), so the stub must accept pipeline input
        # and therefore declare a process block (PSUseProcessBlockForPipeline
        # Command). Individual tests Mock this, so the body stays a no-op.
        process { }
    }

    # The SUT dot-sources the reconciler's pure resolvers at load; those define
    # functions only (no top-level side effects) and reference Common.
    # PowerShell's retry helper only when called, so this dot-source is safe
    # with no module import. The run-guard in the SUT skips its entry block on
    # a dot-source, so nothing executes here beyond function definition.
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\Ansible\ops\Stage-ToolchainArtifacts.ps1"
}

Describe 'Stage-ToolchainArtifacts' {

    Context 'Read-ToolchainDesiredState source selection' {
        It 'rejects supplying neither a config path nor a secret suffix' {
            { Read-ToolchainDesiredState } |
                Should -Throw '*exactly one*'
        }

        It 'rejects supplying both a config path and a secret suffix' {
            { Read-ToolchainDesiredState -ConfigPath 'x' -Suffix 'Production' } |
                Should -Throw '*exactly one*'
        }
    }

    Context 'Read-ToolchainDesiredState source B (VmProvisionerConfig)' {
        It 'reads VmProvisionerConfig by suffix and projects to a per-host map' {
            # Source B reads the per-VM inventory vault and projects it to the
            # per-host map keyed by vmName; mock the vault read and let the real
            # projection run so each host keeps ONLY its own toolchains.
            Mock Read-VmProvisionerConfig {
                @(
                    [pscustomobject]@{ vmName = 'a'; kind = 'workload'
                                       javaDevKit = [pscustomobject]@{ vendor = 'temurin'; version = '21' } },
                    [pscustomobject]@{ vmName = 'b'; kind = 'workload'
                                       dotnetSdk = [pscustomobject]@{ channel = '10.0'; version = '10.0.100' } }
                )
            }

            $result = Read-ToolchainDesiredState -Suffix 'Production'

            Should -Invoke Read-VmProvisionerConfig -Times 1 -Exactly `
                -ParameterFilter { $SecretSuffix -eq 'Production' }
            $result.a.jdk_versions                   | Should -Be @('21')
            @($result.a.dotnet_sdk_versions).Count   | Should -Be 0
            $result.b.dotnet_sdk_versions[0].channel | Should -Be '10.0'
            @($result.b.jdk_versions).Count          | Should -Be 0
        }
    }

    Context 'empty fleet (no VM requests any toolchain)' {
        It 'emits the contract and an empty per-host map without touching upstream' {
            # An empty per-host map must not throw (the StrictMode .Properties
            # trap) and must stage nothing.
            Mock Read-ToolchainDesiredState { [pscustomobject]@{} }
            Mock Resolve-AdoptiumRelease {}
            Mock New-Item {}
            Mock Set-Content {}

            $out = Invoke-ToolchainStaging `
                -ConfigPath        'ignored-mocked' `
                -StagingDirectory  'TestDrive:\staging' `
                -ResolvedConfigOut 'TestDrive:\resolved.json'

            Should -Not -Invoke Resolve-AdoptiumRelease
            Should -Invoke Set-Content -Times 1 -ParameterFilter {
                $Value -like '*toolchains_resolved_by_host*'
            }
            ($out -join "`n") | Should -Match 'STAGING_DIR='
        }
    }

    Context 'checksum verification gate (a JDK pin)' {
        BeforeEach {
            # One JDK pin desired; no .NET SDK / tools, so only the JDK path
            # exercises the gate.
            Mock Read-ToolchainDesiredState {
                # Per-host map: one host wanting one JDK.
                [pscustomobject]@{
                    'node-01' = [pscustomobject]@{
                        jdk_versions        = @('21')
                        dotnet_sdk_versions = @()
                        dotnet_tools_tools  = @()
                    }
                }
            }
            Mock Resolve-AdoptiumRelease {
                @{
                    ResolvedVersion = '21.0.5+11'
                    Sha256          = 'EXPECTEDHASH'
                    DownloadUrl     = 'https://example.invalid/OpenJDK21U.tar.gz'
                    ArchiveName     = 'OpenJDK21U-jdk_x64_linux_hotspot_21.0.5_11.tar.gz'
                }
            }
            Mock New-Item {}
            Mock Test-Path { $false }   # no cache hit
            Mock Invoke-WebRequest {}
            Mock Remove-Item {}
            Mock Set-Content {}
        }

        It 'throws and stages nothing when the download hash does not match' {
            Mock Get-FileHash { [pscustomobject]@{ Hash = 'TAMPEREDHASH' } }

            {
                Invoke-ToolchainStaging `
                    -ConfigPath        'ignored-mocked' `
                    -StagingDirectory  'TestDrive:\staging' `
                    -ResolvedConfigOut 'TestDrive:\resolved.json'
            } | Should -Throw '*checksum mismatch*'

            # The corrupt download is removed and NOTHING is pinned or written:
            # no per-artifact lockfile and no resolved-config document, so the
            # tampered build never becomes an install target.
            Should -Invoke Remove-Item -Times 1 -Exactly
            Should -Not -Invoke Set-Content
        }

        It 'stages the artifact and pins the concrete version when the hash matches' {
            Mock Get-FileHash { [pscustomobject]@{ Hash = 'EXPECTEDHASH' } }

            $out = Invoke-ToolchainStaging `
                -ConfigPath        'ignored-mocked' `
                -StagingDirectory  'TestDrive:\staging' `
                -ResolvedConfigOut 'TestDrive:\resolved.json'

            # The artifact is fetched to the exact archive name the role pulls
            # by, and the resolved-config document carries the CONCRETE pin
            # (21.0.5+11), not the operator's loose "21" - the pin that stops
            # the target re-resolving to a newer build than was staged.
            Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter {
                $OutFile -like '*OpenJDK21U-jdk_x64_linux_hotspot_21.0.5_11.tar.gz'
            }
            # The pin is nested under the host's own key in the per-host map,
            # not at the document root - proof the resolution is per host.
            Should -Invoke Set-Content -Times 1 -ParameterFilter {
                $Value -like '*toolchains_resolved_by_host*' -and
                $Value -like '*node-01*' -and
                $Value -like '*21.0.5+11*'
            }

            # The stdout contract the bash wrapper parses.
            ($out -join "`n") | Should -Match 'STAGING_DIR='
            ($out -join "`n") | Should -Match 'STAGING_VERSION='
            ($out -join "`n") | Should -Match 'RESOLVED_CONFIG='
        }
    }

    Context 'PowerShell staging (a loose pwsh pin)' {
        BeforeEach {
            # One PowerShell pin desired, deliberately LOOSE ('7.6'). The
            # powershell role composes its archive name from whatever version
            # it is handed and rejects anything but major.minor.patch, so the
            # concrete pin this step writes is the only thing that makes the
            # role's pull resolvable.
            Mock Read-ToolchainDesiredState {
                [pscustomobject]@{
                    'node-01' = [pscustomobject]@{
                        jdk_versions        = @()
                        dotnet_sdk_versions = @()
                        dotnet_tools_tools  = @()
                        powershell_versions = @('7.6')
                    }
                }
            }
            Mock Resolve-PowerShellRelease {
                @{
                    ResolvedVersion = '7.6.4'
                    Sha256          = 'EXPECTEDHASH'
                    DownloadUrl     = 'https://example.invalid/powershell-7.6.4-linux-x64.tar.gz'
                    ArchiveName     = 'powershell-7.6.4-linux-x64.tar.gz'
                }
            }
            Mock New-Item {}
            Mock Test-Path { $false }   # no cache hit
            Mock Invoke-WebRequest {}
            Mock Remove-Item {}
            Mock Set-Content {}
        }

        It 'stages under the archive name the role re-derives, and pins the concrete version' {
            Mock Get-FileHash { [pscustomobject]@{ Hash = 'EXPECTEDHASH' } }

            $null = Invoke-ToolchainStaging `
                -ConfigPath        'ignored-mocked' `
                -StagingDirectory  'TestDrive:\staging' `
                -ResolvedConfigOut 'TestDrive:\resolved.json'

            Should -Invoke Resolve-PowerShellRelease -Times 1 -ParameterFilter {
                $Version -eq '7.6'
            }
            # The staged filename must be exactly what the role composes from
            # the pinned version - a mismatch here is a 404 at converge.
            Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter {
                $OutFile -like '*powershell-7.6.4-linux-x64.tar.gz'
            }
            # The resolved document carries the CONCRETE 7.6.4, never the
            # operator's loose '7.6' - which the role would reject outright.
            Should -Invoke Set-Content -Times 1 -ParameterFilter {
                $Value -like '*powershell_versions*' -and
                $Value -like '*node-01*' -and
                $Value -like '*7.6.4*'
            }
        }

        # The PowerShell tarball reaches the target unverified (the role pulls
        # by name and trusts the file server), so this is the only checksum
        # gate in the whole path.
        It 'throws and stages nothing when the download hash does not match' {
            Mock Get-FileHash { [pscustomobject]@{ Hash = 'TAMPEREDHASH' } }

            {
                Invoke-ToolchainStaging `
                    -ConfigPath        'ignored-mocked' `
                    -StagingDirectory  'TestDrive:\staging' `
                    -ResolvedConfigOut 'TestDrive:\resolved.json'
            } | Should -Throw '*checksum mismatch*'

            Should -Invoke Remove-Item -Times 1 -Exactly
            Should -Not -Invoke Set-Content
        }

        It 'resolves a pin shared by several hosts only once' {
            Mock Get-FileHash { [pscustomobject]@{ Hash = 'EXPECTEDHASH' } }
            Mock Read-ToolchainDesiredState {
                $entry = {
                    [pscustomobject]@{
                        jdk_versions        = @()
                        dotnet_sdk_versions = @()
                        dotnet_tools_tools  = @()
                        powershell_versions = @('7.6')
                    }
                }
                [pscustomobject]@{
                    'node-01' = (& $entry)
                    'node-02' = (& $entry)
                }
            }

            $null = Invoke-ToolchainStaging `
                -ConfigPath        'ignored-mocked' `
                -StagingDirectory  'TestDrive:\staging' `
                -ResolvedConfigOut 'TestDrive:\resolved.json'

            # Memoized across hosts: one upstream metadata round trip, not one
            # per host. api.github.com allows 60 unauthenticated calls an hour,
            # so this matters at fleet scale.
            Should -Invoke Resolve-PowerShellRelease -Times 1 -Exactly
        }
    }
}
