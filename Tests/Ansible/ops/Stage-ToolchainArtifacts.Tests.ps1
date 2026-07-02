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

    Context 'checksum verification gate (a JDK pin)' {
        BeforeEach {
            # One JDK pin desired; no .NET SDK / tools, so only the JDK path
            # exercises the gate.
            Mock Read-ToolchainDesiredState {
                [pscustomobject]@{
                    jdk_versions        = @('21')
                    dotnet_sdk_versions = @()
                    dotnet_tools_tools  = @()
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
            Should -Invoke Set-Content -Times 1 -ParameterFilter {
                $Value -like '*21.0.5+11*'
            }

            # The stdout contract the bash wrapper parses.
            ($out -join "`n") | Should -Match 'STAGING_DIR='
            ($out -join "`n") | Should -Match 'STAGING_VERSION='
            ($out -join "`n") | Should -Match 'RESOLVED_CONFIG='
        }
    }
}
