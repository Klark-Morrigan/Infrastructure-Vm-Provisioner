BeforeAll {
    # Resolve-PowerShellRelease wraps both of its HTTP calls in
    # Invoke-WithRetry (from Common.PowerShell) with the transient network
    # retry strategy. Stub both as pass-throughs so unit tests stay isolated
    # from the real module - the retry policy itself is covered by
    # Common.PowerShell's own tests.
    function Invoke-WithRetry {
        param([scriptblock] $ScriptBlock, [hashtable[]] $RetryStrategy,
              [hashtable] $BackoffStrategy, [int] $MaxAttempts,
              [string] $OperationName)
        return & $ScriptBlock
    }
    function New-TransientNetworkRetryStrategy {
        return @{ Name = 'TransientNetwork'; ShouldRetry = { $false } }
    }

    # ConvertTo-Array is provided by Common.PowerShell at runtime.
    # Stub it here so the unit tests have no cross-repo dependency.
    function ConvertTo-Array {
        param([AllowNull()] $InputObject)
        if ($null -eq $InputObject) { return , @() }
        , @($InputObject)
    }

    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\up\powershell\Resolve-PowerShellRelease.ps1"

    # ------------------------------------------------------------------
    # Builds a GitHub-release-shaped object. Only the fields the resolver
    # inspects are populated - keeps fixtures focused. Assets default to the
    # linux-x64 tarball plus the hash manifest, the pair a real stable
    # release always publishes.
    # ------------------------------------------------------------------
    function New-PowerShellRelease {
        param(
            [string] $Version,
            [bool]   $Prerelease = $false,
            [bool]   $Draft      = $false,
            [string[]] $AssetNames,
            [string] $Tag
        )

        if (-not $Tag) { $Tag = "v$Version" }
        if (-not $AssetNames) {
            $AssetNames = @("powershell-$Version-linux-x64.tar.gz", 'hashes.sha256')
        }

        $assets = foreach ($name in $AssetNames) {
            [pscustomobject]@{
                name                 = $name
                browser_download_url = "https://example.invalid/$Tag/$name"
            }
        }

        return [pscustomobject]@{
            tag_name   = $Tag
            prerelease = $Prerelease
            draft      = $Draft
            assets     = @($assets)
        }
    }

    # A hash manifest covering the given versions' linux-x64 tarballs, in
    # sha256sum binary form ('<hex> *<name>') - the form the real asset uses.
    # Each hash is a distinct 64-hex string so a test can prove the resolver
    # picked the right LINE, not just any line.
    function New-HashManifest {
        param([string[]] $Versions, [string] $Architecture = 'x64')

        $lines = foreach ($v in $Versions) {
            $hex = ($v -replace '\D', '').PadRight(64, 'a').Substring(0, 64)
            "$hex *powershell-$v-linux-$Architecture.tar.gz"
        }
        return ($lines -join "`n")
    }

    # The expected hash for a version, matching New-HashManifest's derivation.
    # The resolver upper-cases what it returns, so the expectation does too.
    function Get-ExpectedHash {
        param([string] $Version)
        return (($Version -replace '\D', '').PadRight(64, 'a').Substring(0, 64)).ToUpperInvariant()
    }
}

Describe 'Resolve-PowerShellRelease' {

    # ------------------------------------------------------------------
    Context 'version granularity: major only' {
    # ------------------------------------------------------------------

        It 'returns the highest stable release of that major' {
            Mock Invoke-PowerShellReleaseList {
                return @(
                    New-PowerShellRelease -Version '7.6.4'
                    New-PowerShellRelease -Version '7.5.9'
                    New-PowerShellRelease -Version '7.4.18'
                )
            }
            Mock Invoke-PowerShellHashManifest {
                return New-HashManifest -Versions @('7.6.4', '7.5.9', '7.4.18')
            }

            $result = Resolve-PowerShellRelease -Version '7'

            $result.ResolvedVersion | Should -Be '7.6.4'
            $result.ArchiveName     | Should -Be 'powershell-7.6.4-linux-x64.tar.gz'
            $result.DownloadUrl     |
                Should -Be 'https://example.invalid/v7.6.4/powershell-7.6.4-linux-x64.tar.gz'
            $result.Sha256          | Should -Be (Get-ExpectedHash -Version '7.6.4')
        }

        # The load-bearing sort. GitHub orders releases newest-CREATED first,
        # so a 7.5.x servicing release published after a 7.6.x appears EARLIER
        # in the list. Taking the head would resolve '7' to 7.5.x.
        It 'picks the highest version even when the list is not version-ordered' {
            Mock Invoke-PowerShellReleaseList {
                return @(
                    New-PowerShellRelease -Version '7.5.9'    # newest by date
                    New-PowerShellRelease -Version '7.6.4'    # newest by version
                    New-PowerShellRelease -Version '7.4.18'
                )
            }
            Mock Invoke-PowerShellHashManifest {
                return New-HashManifest -Versions @('7.5.9', '7.6.4', '7.4.18')
            }

            (Resolve-PowerShellRelease -Version '7').ResolvedVersion | Should -Be '7.6.4'
        }

        # [version] compares component-by-component; a string sort would rank
        # '7.6.9' above '7.6.10'.
        It 'orders versions numerically, not as strings' {
            Mock Invoke-PowerShellReleaseList {
                return @(
                    New-PowerShellRelease -Version '7.6.9'
                    New-PowerShellRelease -Version '7.6.10'
                )
            }
            Mock Invoke-PowerShellHashManifest {
                return New-HashManifest -Versions @('7.6.9', '7.6.10')
            }

            (Resolve-PowerShellRelease -Version '7').ResolvedVersion | Should -Be '7.6.10'
        }
    }

    # ------------------------------------------------------------------
    Context 'version granularity: major.minor' {
    # ------------------------------------------------------------------

        It 'filters mixed minor lines down to the requested minor' {
            Mock Invoke-PowerShellReleaseList {
                return @(
                    New-PowerShellRelease -Version '7.6.4'
                    New-PowerShellRelease -Version '7.5.9'
                    New-PowerShellRelease -Version '7.5.8'
                )
            }
            Mock Invoke-PowerShellHashManifest {
                return New-HashManifest -Versions @('7.6.4', '7.5.9', '7.5.8')
            }

            $result = Resolve-PowerShellRelease -Version '7.5'

            $result.ResolvedVersion | Should -Be '7.5.9'
            $result.Sha256          | Should -Be (Get-ExpectedHash -Version '7.5.9')
        }
    }

    # ------------------------------------------------------------------
    Context 'version granularity: exact major.minor.patch' {
    # ------------------------------------------------------------------

        It 'returns that exact release even when newer ones exist' {
            Mock Invoke-PowerShellReleaseList {
                return @(
                    New-PowerShellRelease -Version '7.6.4'
                    New-PowerShellRelease -Version '7.5.3'
                )
            }
            Mock Invoke-PowerShellHashManifest {
                return New-HashManifest -Versions @('7.6.4', '7.5.3')
            }

            $result = Resolve-PowerShellRelease -Version '7.5.3'

            $result.ResolvedVersion | Should -Be '7.5.3'
            $result.ArchiveName     | Should -Be 'powershell-7.5.3-linux-x64.tar.gz'
        }
    }

    # ------------------------------------------------------------------
    Context 'response shape' {
    # ------------------------------------------------------------------

        # Invoke-RestMethod writes a JSON array to the pipeline as ONE
        # Object[] without enumerating it. If the resolver collected that with
        # a bare @(), it would see a single "release" that is really the whole
        # array and match nothing. This fixture reproduces that exact shape.
        It 'flattens a response delivered as a single array object' {
            Mock Invoke-PowerShellReleaseList {
                # The unary comma reproduces the non-enumerated Object[] the
                # real Invoke-RestMethod hands back.
                return , @(
                    New-PowerShellRelease -Version '7.6.4'
                    New-PowerShellRelease -Version '7.5.9'
                )
            }
            Mock Invoke-PowerShellHashManifest {
                return New-HashManifest -Versions @('7.6.4', '7.5.9')
            }

            (Resolve-PowerShellRelease -Version '7').ResolvedVersion | Should -Be '7.6.4'
        }
    }

    # ------------------------------------------------------------------
    Context 'excluding non-product releases' {
    # ------------------------------------------------------------------

        # A pin of '7' must never resolve to a preview build, however new.
        It 'ignores prereleases' {
            Mock Invoke-PowerShellReleaseList {
                return @(
                    New-PowerShellRelease -Version '7.7.0-preview.3' -Prerelease $true `
                        -Tag 'v7.7.0-preview.3'
                    New-PowerShellRelease -Version '7.6.4'
                )
            }
            Mock Invoke-PowerShellHashManifest { return New-HashManifest -Versions @('7.6.4') }

            (Resolve-PowerShellRelease -Version '7').ResolvedVersion | Should -Be '7.6.4'
        }

        It 'ignores drafts' {
            Mock Invoke-PowerShellReleaseList {
                return @(
                    New-PowerShellRelease -Version '7.6.5' -Draft $true
                    New-PowerShellRelease -Version '7.6.4'
                )
            }
            Mock Invoke-PowerShellHashManifest { return New-HashManifest -Versions @('7.6.4') }

            (Resolve-PowerShellRelease -Version '7').ResolvedVersion | Should -Be '7.6.4'
        }

        # A tag that is not 'v<major>.<minor>.<patch>' is not a product
        # release; skipping beats failing the whole staging run over it.
        It 'skips tags that are not plain three-part versions' {
            Mock Invoke-PowerShellReleaseList {
                return @(
                    New-PowerShellRelease -Version '7.6.5' -Tag 'v7.6.5-rc.1'
                    New-PowerShellRelease -Version '7.6.4'
                )
            }
            Mock Invoke-PowerShellHashManifest { return New-HashManifest -Versions @('7.6.4') }

            (Resolve-PowerShellRelease -Version '7').ResolvedVersion | Should -Be '7.6.4'
        }
    }

    # ------------------------------------------------------------------
    Context 'architecture' {
    # ------------------------------------------------------------------

        It 'splices the requested architecture into the archive name' {
            Mock Invoke-PowerShellReleaseList {
                return @(
                    New-PowerShellRelease -Version '7.6.4' -AssetNames @(
                        'powershell-7.6.4-linux-arm64.tar.gz', 'hashes.sha256'
                    )
                )
            }
            Mock Invoke-PowerShellHashManifest {
                return New-HashManifest -Versions @('7.6.4') -Architecture 'arm64'
            }

            $result = Resolve-PowerShellRelease -Version '7.6.4' -Architecture 'arm64'

            $result.ArchiveName | Should -Be 'powershell-7.6.4-linux-arm64.tar.gz'
            $result.Sha256      | Should -Be (Get-ExpectedHash -Version '7.6.4')
        }

        It 'throws naming the architecture when no matching asset is published' {
            Mock Invoke-PowerShellReleaseList {
                return @(
                    New-PowerShellRelease -Version '7.6.4' -AssetNames @(
                        'powershell-7.6.4-linux-x64.tar.gz', 'hashes.sha256'
                    )
                )
            }
            Mock Invoke-PowerShellHashManifest { return New-HashManifest -Versions @('7.6.4') }

            { Resolve-PowerShellRelease -Version '7.6.4' -Architecture 'riscv64' } |
                Should -Throw -ExpectedMessage '*riscv64*'
        }
    }

    # ------------------------------------------------------------------
    Context 'rejecting unresolvable input' {
    # ------------------------------------------------------------------

        It 'throws on an unrecognised granularity and names the accepted forms' {
            # No network mock needed - the parse gate rejects before any call.
            { Resolve-PowerShellRelease -Version 'latest' } |
                Should -Throw -ExpectedMessage "*not a recognised granularity*'7', '7.6' or '7.6.4'*"
        }

        It 'throws on a v-prefixed version' {
            { Resolve-PowerShellRelease -Version 'v7.6.4' } |
                Should -Throw -ExpectedMessage '*not a recognised granularity*'
        }

        It 'throws when the endpoint returns no releases at all' {
            Mock Invoke-PowerShellReleaseList { return @() }

            { Resolve-PowerShellRelease -Version '7' } |
                Should -Throw -ExpectedMessage '*returned no releases*'
        }

        It 'throws when no stable release matches the pin' {
            Mock Invoke-PowerShellReleaseList {
                return @(New-PowerShellRelease -Version '7.6.4')
            }

            { Resolve-PowerShellRelease -Version '7.99' } |
                Should -Throw -ExpectedMessage "*no stable PowerShell release matches version '7.99'*"
        }
    }

    # ------------------------------------------------------------------
    Context 'checksum availability' {
    # ------------------------------------------------------------------

        # The Ansible role pulls from the file server without verifying
        # anything, so this resolver is the only checksum gate. An
        # unverifiable artifact must fail rather than stage.
        It 'refuses to resolve a release that publishes no hash manifest' {
            Mock Invoke-PowerShellReleaseList {
                return @(
                    New-PowerShellRelease -Version '7.6.4' -AssetNames @(
                        'powershell-7.6.4-linux-x64.tar.gz'
                    )
                )
            }

            { Resolve-PowerShellRelease -Version '7.6.4' } |
                Should -Throw -ExpectedMessage '*unverifiable artifact*'
        }

        It 'refuses to resolve when the manifest has no line for the archive' {
            Mock Invoke-PowerShellReleaseList {
                return @(New-PowerShellRelease -Version '7.6.4')
            }
            # A manifest that covers only some other version's tarball.
            Mock Invoke-PowerShellHashManifest { return New-HashManifest -Versions @('7.5.9') }

            { Resolve-PowerShellRelease -Version '7.6.4' } |
                Should -Throw -ExpectedMessage '*no entry for*powershell-7.6.4-linux-x64.tar.gz*'
        }
    }
}

Describe 'Get-PowerShellAssetHash' {

    # Parsing is split from the resolver precisely so these cases need no
    # network mock at all - the manifest's format is a property of the
    # upstream file, not of release resolution.

    It 'reads a hash from sha256sum binary form and upper-cases it' {
        $hex = 'a' * 64
        $manifest = "$hex *powershell-7.6.4-linux-x64.tar.gz"

        Get-PowerShellAssetHash -ManifestText $manifest `
            -AssetName 'powershell-7.6.4-linux-x64.tar.gz' |
            Should -Be ('A' * 64)
    }

    # sha256sum's text mode omits the '*'; accept both so a mode change
    # upstream does not break staging.
    It 'reads a hash from sha256sum text form' {
        $hex = 'b' * 64
        $manifest = "$hex  powershell-7.6.4-linux-x64.tar.gz"

        Get-PowerShellAssetHash -ManifestText $manifest `
            -AssetName 'powershell-7.6.4-linux-x64.tar.gz' |
            Should -Be ('B' * 64)
    }

    It 'selects the requested asset out of a multi-platform manifest' {
        $manifest = @(
            ('1' * 64) + ' *powershell-7.6.4-linux-arm64.tar.gz'
            ('2' * 64) + ' *powershell-7.6.4-linux-x64.tar.gz'
            ('3' * 64) + ' *powershell-7.6.4-1.rh.x86_64.rpm'
        ) -join "`n"

        Get-PowerShellAssetHash -ManifestText $manifest `
            -AssetName 'powershell-7.6.4-linux-x64.tar.gz' |
            Should -Be ('2' * 64)
    }

    It 'tolerates CRLF line endings and blank lines' {
        $manifest = "`r`n" + ('c' * 64) + " *powershell-7.6.4-linux-x64.tar.gz`r`n`r`n"

        Get-PowerShellAssetHash -ManifestText $manifest `
            -AssetName 'powershell-7.6.4-linux-x64.tar.gz' |
            Should -Be ('C' * 64)
    }

    It 'throws when the asset has no line in the manifest' {
        { Get-PowerShellAssetHash -ManifestText (('d' * 64) + ' *other.tar.gz') `
                -AssetName 'powershell-7.6.4-linux-x64.tar.gz' } |
            Should -Throw -ExpectedMessage '*no entry for*'
    }

    It 'throws on an empty manifest' {
        { Get-PowerShellAssetHash -ManifestText '' -AssetName 'anything.tar.gz' } |
            Should -Throw -ExpectedMessage '*no entry for*'
    }
}

Describe 'Invoke-PowerShellHashManifest' {

    # The real asset is UTF-16LE with a BOM served as application/octet-stream,
    # so Invoke-WebRequest hands back a byte[]. A default UTF-8 decode over
    # those bytes yields NUL between every character and matches nothing -
    # which is why the decode is explicit.

    It 'decodes a UTF-16LE byte array and strips the BOM' {
        $line = ('e' * 64) + ' *powershell-7.6.4-linux-x64.tar.gz'
        # The [byte[]] cast is required, not cosmetic: concatenating two
        # byte arrays with '+' yields an Object[], which would not satisfy
        # the resolver's `-is [byte[]]` test and would send this fixture
        # down the already-a-string branch instead of the decode branch.
        # Invoke-WebRequest itself returns a genuine byte[].
        [byte[]] $bytes = [System.Text.Encoding]::Unicode.GetPreamble() +
                          [System.Text.Encoding]::Unicode.GetBytes($line)

        Mock Invoke-WebRequest { return [pscustomobject]@{ Content = $bytes } }

        $text = Invoke-PowerShellHashManifest -Url 'https://example.invalid/hashes.sha256'

        # BOM gone, so the hash is the very first character.
        $text | Should -Be $line
        Get-PowerShellAssetHash -ManifestText $text `
            -AssetName 'powershell-7.6.4-linux-x64.tar.gz' |
            Should -Be ('E' * 64)
    }

    # A mocked or proxied response may already be decoded; attempting a byte
    # decode on a string would throw, so both shapes are tolerated.
    It 'passes an already-decoded string through unchanged' {
        $line = ('f' * 64) + ' *powershell-7.6.4-linux-x64.tar.gz'

        Mock Invoke-WebRequest { return [pscustomobject]@{ Content = $line } }

        Invoke-PowerShellHashManifest -Url 'https://example.invalid/hashes.sha256' |
            Should -Be $line
    }
}
