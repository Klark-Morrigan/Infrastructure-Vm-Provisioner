BeforeAll {
    # Resolve-DotnetSdkRelease wraps its Invoke-RestMethod call in
    # Invoke-WithRetry (from PowerShell.Common) with the transient
    # network retry strategy. Stub both as pass-throughs so unit tests
    # stay isolated from the real module - the retry policy itself is
    # covered by PowerShell.Common's own tests.
    function Invoke-WithRetry {
        param([scriptblock] $ScriptBlock, [hashtable[]] $RetryStrategy,
              [hashtable] $BackoffStrategy, [int] $MaxAttempts,
              [string] $OperationName)
        return & $ScriptBlock
    }
    function New-TransientNetworkRetryStrategy {
        return @{ Name = 'TransientNetwork'; ShouldRetry = { $false } }
    }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\dotnet\Resolve-DotnetSdkRelease.ps1"

    # ------------------------------------------------------------------
    # Loads the canned channel-10.0 fixture as a parsed object, matching
    # what Invoke-RestMethod would return. Re-read per call so a test
    # that mutates the object cannot bleed into the next.
    # ------------------------------------------------------------------
    function Get-Fixture10 {
        $path = Join-Path $PSScriptRoot 'fixtures\releases-10.0.json'
        return Get-Content -Path $path -Raw | ConvertFrom-Json
    }
}

Describe 'Resolve-DotnetSdkRelease' {

    # ------------------------------------------------------------------
    Context 'version granularity: major only' {
    # ------------------------------------------------------------------

        It "returns the feed's latest-sdk and its linux-x64 file" {
            Mock Invoke-DotnetSdkReleasesJson {
                param($Channel)
                $Channel | Should -Be '10.0'
                return Get-Fixture10
            }

            $result = Resolve-DotnetSdkRelease -Channel '10.0' -RequestedVersion '10'

            $result.ResolvedVersion | Should -Be '10.0.100'
            $result.Sha512          | Should -Be 'sha512-10.0.100-linux-x64'
            $result.DownloadUrl     | Should -Be 'https://example.invalid/dotnet-sdk-10.0.100-linux-x64.tar.gz'
            $result.SourceUrl       | Should -Be 'https://builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json'
        }
    }

    # ------------------------------------------------------------------
    Context 'version granularity: major.minor' {
    # ------------------------------------------------------------------

        It "behaves identically to major-only (same latest-sdk path)" {
            Mock Invoke-DotnetSdkReleasesJson { return Get-Fixture10 }

            $result = Resolve-DotnetSdkRelease -Channel '10.0' -RequestedVersion '10.0'

            $result.ResolvedVersion | Should -Be '10.0.100'
            $result.DownloadUrl     | Should -Be 'https://example.invalid/dotnet-sdk-10.0.100-linux-x64.tar.gz'
        }
    }

    # ------------------------------------------------------------------
    Context 'version granularity: exact major.minor.patch' {
    # ------------------------------------------------------------------

        It "returns the exact SDK when present in releases[].sdks[]" {
            Mock Invoke-DotnetSdkReleasesJson { return Get-Fixture10 }

            $result = Resolve-DotnetSdkRelease -Channel '10.0' -RequestedVersion '10.0.101'

            $result.ResolvedVersion | Should -Be '10.0.101'
            $result.Sha512          | Should -Be 'sha512-10.0.101-linux-x64'
        }

        It "finds an SDK inside a release whose release-version differs" {
            # 10.0.099 sits inside the '10.0.0-preview' release entry; this
            # exercises the inner-loop scan across releases.
            Mock Invoke-DotnetSdkReleasesJson { return Get-Fixture10 }

            $result = Resolve-DotnetSdkRelease -Channel '10.0' -RequestedVersion '10.0.099'

            $result.ResolvedVersion | Should -Be '10.0.099'
        }
    }

    # ------------------------------------------------------------------
    Context 'no match' {
    # ------------------------------------------------------------------

        It "throws with the available SDK list when the exact version is absent" {
            Mock Invoke-DotnetSdkReleasesJson { return Get-Fixture10 }

            { Resolve-DotnetSdkRelease -Channel '10.0' -RequestedVersion '10.0.999' } |
                Should -Throw -ExpectedMessage "*10.0.999*Available SDKs:*10.0.100*"
        }

        It "throws when the feed has no latest-sdk and the request is granular" {
            Mock Invoke-DotnetSdkReleasesJson {
                $f = Get-Fixture10
                $f.PSObject.Properties.Remove('latest-sdk')
                return $f
            }

            { Resolve-DotnetSdkRelease -Channel '10.0' -RequestedVersion '10' } |
                Should -Throw -ExpectedMessage "*no 'latest-sdk' field*"
        }
    }

    # ------------------------------------------------------------------
    Context 'network and input failures' {
    # ------------------------------------------------------------------

        It "surfaces the channel URL when Invoke-DotnetSdkReleasesJson throws" {
            Mock Invoke-DotnetSdkReleasesJson { throw 'DNS failure' }

            { Resolve-DotnetSdkRelease -Channel '10.0' -RequestedVersion '10' } |
                Should -Throw -ExpectedMessage "*release-metadata/10.0/releases.json*DNS failure*"
        }

        It "throws on an unrecognised version granularity" {
            { Resolve-DotnetSdkRelease -Channel '10.0' -RequestedVersion '10.0.100-rc1' } |
                Should -Throw -ExpectedMessage "*granularity*"
        }

        It "throws when the matched SDK has no linux-x64 .tar.gz file" {
            Mock Invoke-DotnetSdkReleasesJson {
                $f = Get-Fixture10
                # Drop the linux-x64 file from the 10.0.100 SDK so only
                # the win-x64 entry remains.
                $sdk = $f.releases[0].sdks[0]
                $sdk.files = @($sdk.files | Where-Object { $_.rid -ne 'linux-x64' })
                return $f
            }

            { Resolve-DotnetSdkRelease -Channel '10.0' -RequestedVersion '10' } |
                Should -Throw -ExpectedMessage "*10.0.100*linux-x64*"
        }
    }

    # ------------------------------------------------------------------
    Context 'returned object shape' {
    # ------------------------------------------------------------------

        It "returns a PSCustomObject with the four documented properties" {
            Mock Invoke-DotnetSdkReleasesJson { return Get-Fixture10 }

            $result = Resolve-DotnetSdkRelease -Channel '10.0' -RequestedVersion '10'

            $result | Should -BeOfType [pscustomobject]
            ($result.PSObject.Properties.Name | Sort-Object) |
                Should -Be @('DownloadUrl', 'ResolvedVersion', 'Sha512', 'SourceUrl')
        }
    }
}
