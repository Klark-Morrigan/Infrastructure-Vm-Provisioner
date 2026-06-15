BeforeAll {
    # Stub every cmdlet that touches the network or real filesystem.
    # Individual tests override these with Mock; the BeforeAll bodies
    # exist only so Pester has a function to mock against (Pester's
    # Mock cannot intercept cmdlet calls unless the symbol resolves to
    # something in the test scope first).
    function Test-Path         { param($Path, $PathType) }
    function Get-Content       { param($Path, [switch]$Raw) }
    function Set-Content       { param($Path, $Value, $Encoding) }
    function Get-FileHash      { param($Path, $Algorithm) }
    function Invoke-WebRequest { param($Uri, $OutFile, [switch]$UseBasicParsing) }
    function Remove-Item       { param($Path, [switch]$Force, $ErrorAction) }

    # Stub the resolver before dot-sourcing the acquisition script so
    # the function call inside Invoke-DotnetSdkAcquisition binds to the
    # stub instead of the real implementation (which would otherwise
    # hit the live release-metadata feed).
    function Resolve-DotnetSdkRelease {
        param([string] $Channel, [string] $RequestedVersion)
        return [pscustomobject]@{
            ResolvedVersion = '10.0.100'
            Sha512          = 'AAAA'
            DownloadUrl     = 'https://example.invalid/dotnet-sdk-10.0.100-linux-x64.tar.gz'
            SourceUrl       = 'https://example.invalid/feed/10.0/releases.json'
        }
    }

    # Retry seam stubs: pass-through and a sentinel strategy. Real retry
    # behaviour is covered by Common.PowerShell's own tests.
    function Invoke-WithRetry {
        param([scriptblock] $ScriptBlock, [hashtable[]] $RetryStrategy,
              [hashtable] $BackoffStrategy, [int] $MaxAttempts,
              [string] $OperationName)
        return & $ScriptBlock
    }
    function New-TransientNetworkRetryStrategy {
        return @{ Name = 'TransientNetwork'; ShouldRetry = { $false } }
    }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\dotnet\Invoke-DotnetSdkAcquisition.ps1"

    # Minimal VM with a populated dotnetSdk field. Cache paths derived
    # inside the function:
    #   lockKey     = 'dotnet-sdk-10.0-linux-x64'
    #   lockPath    = 'C:\VHDs\dotnet-sdk-10.0-linux-x64.lock.json'
    #   tarballPath = 'C:\VHDs\dotnet-sdk-10.0.100-linux-x64.tar.gz'
    # (tarball is keyed by resolvedVersion, lockfile by requestedVersion).
    function New-TestVm {
        [PSCustomObject]@{
            vmName    = 'node-01'
            vhdPath   = 'C:\VHDs'
            dotnetSdk = [PSCustomObject]@{
                channel = '10.0'
                version = '10.0'
            }
        }
    }

    # Lockfile JSON returned by mocked Get-Content. The sha512 matches
    # the resolver-stub's 'AAAA' on purpose so cache-hit paths hash-
    # compare cleanly.
    $script:LockJson = @{
        resolvedVersion = '10.0.100'
        sha512          = 'AAAA'
        sourceUrl       = 'https://example.invalid/dotnet-sdk-10.0.100-linux-x64.tar.gz'
        downloadedUtc   = '2026-05-01T00:00:00.0000000Z'
    } | ConvertTo-Json
}

Describe 'Invoke-DotnetSdkAcquisition' {

    # ------------------------------------------------------------------
    Context 'cache hit: lockfile present, tarball hash matches' {
    # ------------------------------------------------------------------

        It 'does not resolve or download, populates _dotnetSdk* fields' {
            Mock Test-Path             { return $true }
            Mock Get-Content           { return $script:LockJson }
            Mock Get-FileHash          { return [pscustomobject]@{ Hash = 'AAAA' } }
            Mock Invoke-WebRequest     { }
            Mock Set-Content           { }
            Mock Resolve-DotnetSdkRelease { throw 'resolver must not be called on cache hit' }

            $vm = New-TestVm
            Invoke-DotnetSdkAcquisition -Vm $vm -CacheDir 'C:\VHDs'

            Should -Invoke Resolve-DotnetSdkRelease -Times 0
            Should -Invoke Invoke-WebRequest        -Times 0
            Should -Invoke Set-Content              -Times 0

            $vm._dotnetSdkTarballPath     | Should -Be 'C:\VHDs\dotnet-sdk-10.0.100-linux-x64.tar.gz'
            $vm._dotnetSdkResolvedVersion | Should -Be '10.0.100'
        }
    }

    # ------------------------------------------------------------------
    Context 'cache hit with hash mismatch: one retry recovers' {
    # ------------------------------------------------------------------

        It 're-downloads from the pinned sourceUrl and succeeds' {
            Mock Test-Path   { return $true }
            Mock Get-Content { return $script:LockJson }

            # First hash (corruption check) wrong; second (post-redownload)
            # right. Pester's Mock script-block is invoked per call - a
            # counter varies behaviour across the two calls.
            $script:hashCalls = 0
            Mock Get-FileHash {
                $script:hashCalls++
                if ($script:hashCalls -eq 1) {
                    return [pscustomobject]@{ Hash = 'BBBB' }   # corrupt
                }
                return [pscustomobject]@{ Hash = 'AAAA' }       # after redownload
            }
            Mock Invoke-WebRequest { }
            Mock Resolve-DotnetSdkRelease { throw 'resolver must not be called on retry' }

            $vm = New-TestVm
            Invoke-DotnetSdkAcquisition -Vm $vm -CacheDir 'C:\VHDs'

            Should -Invoke Resolve-DotnetSdkRelease -Times 0
            Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter {
                $Uri -eq 'https://example.invalid/dotnet-sdk-10.0.100-linux-x64.tar.gz'
            }
            $vm._dotnetSdkTarballPath | Should -Be 'C:\VHDs\dotnet-sdk-10.0.100-linux-x64.tar.gz'
        }
    }

    # ------------------------------------------------------------------
    Context 'cache hit with hash mismatch: second mismatch throws' {
    # ------------------------------------------------------------------

        It 'throws naming both the expected and actual hashes' {
            Mock Test-Path   { return $true }
            Mock Get-Content { return $script:LockJson }
            # Both checks return the same wrong hash.
            Mock Get-FileHash { return [pscustomobject]@{ Hash = 'BBBB' } }
            Mock Invoke-WebRequest { }

            $vm  = New-TestVm
            $err = $null
            try { Invoke-DotnetSdkAcquisition -Vm $vm -CacheDir 'C:\VHDs' }
            catch { $err = $_ }

            $err            | Should -Not -BeNullOrEmpty
            $err.ToString() | Should -Match 'AAAA'
            $err.ToString() | Should -Match 'BBBB'
        }
    }

    # ------------------------------------------------------------------
    Context 'cache hit, pinned URL fails: throws with delete-lockfile hint' {
    # ------------------------------------------------------------------

        It 'surfaces the lockfile path and a deletion hint' {
            Mock Test-Path   { param($Path, $PathType)
                # Lockfile exists; tarball does not - forces the redownload
                # branch (which then fails).
                if ($Path -match '\.lock\.json$') { return $true }
                return $false
            }
            Mock Get-Content       { return $script:LockJson }
            Mock Get-FileHash      { return [pscustomobject]@{ Hash = 'AAAA' } }
            Mock Invoke-WebRequest { throw '404 Not Found' }

            $vm = New-TestVm
            { Invoke-DotnetSdkAcquisition -Vm $vm -CacheDir 'C:\VHDs' } |
                Should -Throw -ExpectedMessage '*Delete*lock*'
        }
    }

    # ------------------------------------------------------------------
    Context 'true cache miss: no lockfile' {
    # ------------------------------------------------------------------

        It 'resolves, downloads, verifies, writes lockfile, sets _dotnetSdk*' {
            Mock Test-Path        { return $false }
            Mock Get-FileHash     { return [pscustomobject]@{ Hash = 'AAAA' } }
            Mock Invoke-WebRequest { }
            Mock Set-Content      { }
            # Pester needs an explicit Mock (not just the BeforeAll stub)
            # for Should -Invoke counting to work.
            Mock Resolve-DotnetSdkRelease {
                return [pscustomobject]@{
                    ResolvedVersion = '10.0.100'
                    Sha512          = 'AAAA'
                    DownloadUrl     = 'https://example.invalid/dotnet-sdk-10.0.100-linux-x64.tar.gz'
                    SourceUrl       = 'https://example.invalid/feed/10.0/releases.json'
                }
            }

            $vm = New-TestVm
            Invoke-DotnetSdkAcquisition -Vm $vm -CacheDir 'C:\VHDs'

            Should -Invoke Resolve-DotnetSdkRelease -Times 1 -ParameterFilter {
                $Channel -eq '10.0' -and $RequestedVersion -eq '10.0'
            }
            Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter {
                $Uri -eq 'https://example.invalid/dotnet-sdk-10.0.100-linux-x64.tar.gz'
            }
            Should -Invoke Set-Content -Times 1 -ParameterFilter {
                $Path -match '\.lock\.json$'
            }
            $vm._dotnetSdkTarballPath     | Should -Be 'C:\VHDs\dotnet-sdk-10.0.100-linux-x64.tar.gz'
            $vm._dotnetSdkResolvedVersion | Should -Be '10.0.100'
        }
    }

    # ------------------------------------------------------------------
    Context 'fresh download: hash mismatch' {
    # ------------------------------------------------------------------

        It 'throws and does not write a lockfile' {
            Mock Test-Path        { return $false }
            # Resolver advertised 'AAAA' but the file hashes to 'BBBB'.
            Mock Get-FileHash     { return [pscustomobject]@{ Hash = 'BBBB' } }
            Mock Invoke-WebRequest { }
            Mock Set-Content      { }
            Mock Remove-Item      { }

            $vm = New-TestVm
            { Invoke-DotnetSdkAcquisition -Vm $vm -CacheDir 'C:\VHDs' } |
                Should -Throw -ExpectedMessage '*hash mismatch*'

            Should -Invoke Set-Content -Times 0
        }
    }

    # ------------------------------------------------------------------
    Context 'dotnetSdk absent / null / empty' {
    # ------------------------------------------------------------------

        It 'returns silently with no resolver or network call when absent' {
            Mock Resolve-DotnetSdkRelease { throw 'must not be called' }
            Mock Invoke-WebRequest        { throw 'must not be called' }

            $vm = [PSCustomObject]@{ vmName = 'node-01'; vhdPath = 'C:\VHDs' }
            Invoke-DotnetSdkAcquisition -Vm $vm -CacheDir 'C:\VHDs'

            Should -Invoke Resolve-DotnetSdkRelease -Times 0
            Should -Invoke Invoke-WebRequest        -Times 0
            $vm.PSObject.Properties['_dotnetSdkTarballPath'] | Should -BeNullOrEmpty
        }

        It 'returns silently when dotnetSdk is null' {
            Mock Resolve-DotnetSdkRelease { throw 'must not be called' }

            $vm = [PSCustomObject]@{
                vmName    = 'node-01'
                vhdPath   = 'C:\VHDs'
                dotnetSdk = $null
            }
            Invoke-DotnetSdkAcquisition -Vm $vm -CacheDir 'C:\VHDs'

            Should -Invoke Resolve-DotnetSdkRelease -Times 0
        }

        It 'returns silently when dotnetSdk is an empty array' {
            Mock Resolve-DotnetSdkRelease { throw 'must not be called' }

            $vm = [PSCustomObject]@{
                vmName    = 'node-01'
                vhdPath   = 'C:\VHDs'
                dotnetSdk = @()
            }
            Invoke-DotnetSdkAcquisition -Vm $vm -CacheDir 'C:\VHDs'

            Should -Invoke Resolve-DotnetSdkRelease -Times 0
        }
    }
}
