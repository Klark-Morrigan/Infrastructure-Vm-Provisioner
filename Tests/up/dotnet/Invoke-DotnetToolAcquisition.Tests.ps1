BeforeAll {
    # Stub every cmdlet / function the acquirer reaches into so Pester
    # can intercept the calls. The bodies below exist only so the
    # symbol resolves in test scope; individual It blocks override them
    # with Mock.
    function Test-Path         { param($Path, $PathType) }
    function Get-Content       { param($Path, [switch]$Raw) }
    function Set-Content       { param($Path, $Value, $Encoding) }
    function Get-FileHash      { param($Path, $Algorithm) }
    function Invoke-WebRequest { param($Uri, $OutFile, [switch]$UseBasicParsing) }
    function Invoke-RestMethod { param($Uri, [switch]$UseBasicParsing) }
    function Remove-Item       { param($Path, [switch]$Force, $ErrorAction) }
    function Move-Item         { param($Path, $Destination, [switch]$Force) }

    # Retry seam stubs - pass-through. Retry behaviour itself is covered
    # by Infrastructure.Common's own tests.
    function Invoke-WithRetry {
        param([scriptblock] $ScriptBlock, [hashtable[]] $RetryStrategy,
              [hashtable] $BackoffStrategy, [int] $MaxAttempts,
              [string] $OperationName)
        return & $ScriptBlock
    }
    function New-TransientNetworkRetryStrategy {
        return @{ Name = 'TransientNetwork'; ShouldRetry = { $false } }
    }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\dotnet\Invoke-DotnetToolAcquisition.ps1"

    # Canonical fixtures shared across It blocks.
    #   - $script:KnownHashHex matches what Get-FileHash mocks return.
    #   - $script:KnownHashBase64 is the same bytes in base64; the
    #     registration leaf returns it in that encoding.
    $bytes = New-Object byte[] 64
    for ($i = 0; $i -lt 64; $i++) { $bytes[$i] = 0xAA }
    $script:KnownHashBase64 = [System.Convert]::ToBase64String($bytes)
    $script:KnownHashHex    =
        ([System.BitConverter]::ToString($bytes)).Replace('-', '').ToUpperInvariant()

    function New-TestVm {
        param([object[]] $Tools)
        return [PSCustomObject]@{
            vmName      = 'node-01'
            vhdPath     = 'C:\VHDs'
            dotnetTools = $Tools
        }
    }

    function New-ToolEntry {
        param([string] $Id, [string] $Version)
        return [PSCustomObject]@{ id = $Id; version = $Version }
    }

    function New-LockJson {
        param([string] $Id, [string] $Version, [string] $Sha512)
        return @{
            id         = $Id
            version    = $Version
            nupkg      = "dotnet-tool-$Id-$Version.nupkg"
            sha512     = $Sha512
            source     = "https://www.nuget.org/api/v2/package/$Id/$Version"
            acquiredAt = '2026-05-01T00:00:00.0000000Z'
        } | ConvertTo-Json
    }
}

Describe 'Invoke-DotnetToolAcquisition' {

    # ------------------------------------------------------------------
    Context 'absent / null / empty dotnetTools' {
    # ------------------------------------------------------------------

        It 'returns silently when the field is absent' {
            Mock Invoke-WebRequest        { throw 'must not be called' }
            Mock Invoke-RestMethod        { throw 'must not be called' }
            Mock Invoke-DotnetNugetVerify { throw 'must not be called' }

            $vm = [PSCustomObject]@{ vmName = 'node-01'; vhdPath = 'C:\VHDs' }
            Invoke-DotnetToolAcquisition -Vm $vm -CacheDir 'C:\VHDs'

            Should -Invoke Invoke-WebRequest        -Times 0
            Should -Invoke Invoke-RestMethod        -Times 0
            Should -Invoke Invoke-DotnetNugetVerify -Times 0
            $vm.PSObject.Properties['_dotnetToolNupkgPaths'] | Should -BeNullOrEmpty
        }

        It 'returns silently when dotnetTools is null' {
            Mock Invoke-WebRequest { throw 'must not be called' }

            $vm = New-TestVm -Tools $null
            Invoke-DotnetToolAcquisition -Vm $vm -CacheDir 'C:\VHDs'

            Should -Invoke Invoke-WebRequest -Times 0
        }

        It 'returns silently when dotnetTools is an empty array' {
            Mock Invoke-WebRequest { throw 'must not be called' }

            $vm = New-TestVm -Tools @()
            Invoke-DotnetToolAcquisition -Vm $vm -CacheDir 'C:\VHDs'

            Should -Invoke Invoke-WebRequest -Times 0
        }
    }

    # ------------------------------------------------------------------
    Context 'cache hit: lockfile + nupkg present, SHA matches' {
    # ------------------------------------------------------------------

        It 'skips download / registration / verify and stamps the path' {
            Mock Test-Path                { return $true }
            Mock Get-Content              {
                return (New-LockJson -Id 'pkg.a' -Version '1.0.0' -Sha512 $script:KnownHashHex)
            }
            Mock Get-FileHash             { return [pscustomobject]@{ Hash = $script:KnownHashHex } }
            Mock Invoke-WebRequest        { throw 'must not download on cache hit' }
            Mock Invoke-RestMethod        { throw 'must not fetch metadata on cache hit' }
            Mock Invoke-DotnetNugetVerify { throw 'must not verify on cache hit' }
            Mock Set-Content              { throw 'must not write lockfile on cache hit' }
            Mock Move-Item                { throw 'must not move on cache hit' }

            $vm = New-TestVm -Tools @((New-ToolEntry 'pkg.a' '1.0.0'))
            Invoke-DotnetToolAcquisition -Vm $vm -CacheDir 'C:\VHDs'

            Should -Invoke Invoke-WebRequest        -Times 0
            Should -Invoke Invoke-RestMethod        -Times 0
            Should -Invoke Invoke-DotnetNugetVerify -Times 0
            Should -Invoke Set-Content              -Times 0

            $vm._dotnetToolNupkgPaths['pkg.a@1.0.0'] |
                Should -Be 'C:\VHDs\dotnet-tool-pkg.a-1.0.0.nupkg'
        }
    }

    # ------------------------------------------------------------------
    Context 'cache miss: happy path' {
    # ------------------------------------------------------------------

        It 'downloads, verifies SHA, verifies signature, writes lockfile, stamps path' {
            Mock Test-Path                { return $false }
            Mock Get-FileHash             { return [pscustomobject]@{ Hash = $script:KnownHashHex } }
            Mock Invoke-WebRequest        { }
            Mock Invoke-RestMethod        {
                return [pscustomobject]@{
                    packageHash          = $script:KnownHashBase64
                    packageHashAlgorithm = 'SHA512'
                }
            }
            Mock Invoke-DotnetNugetVerify { return [pscustomobject]@{ ExitCode = 0; Output = '' } }
            Mock Move-Item                { }
            Mock Set-Content              { }
            Mock Remove-Item              { }

            $vm = New-TestVm -Tools @((New-ToolEntry 'pkg.a' '1.0.0'))
            Invoke-DotnetToolAcquisition -Vm $vm -CacheDir 'C:\VHDs'

            Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter {
                $Uri -eq 'https://www.nuget.org/api/v2/package/pkg.a/1.0.0'
            }
            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Uri -eq 'https://api.nuget.org/v3/registration5-semver1/pkg.a/1.0.0.json'
            }
            Should -Invoke Invoke-DotnetNugetVerify -Times 1 -ParameterFilter {
                $ConfigPath -match 'nuget-trusted-signers\.config$'
            }
            Should -Invoke Move-Item   -Times 1
            Should -Invoke Set-Content -Times 1 -ParameterFilter {
                $Path -match '\.lock\.json$'
            }

            $vm._dotnetToolNupkgPaths['pkg.a@1.0.0'] |
                Should -Be 'C:\VHDs\dotnet-tool-pkg.a-1.0.0.nupkg'
        }

        It 'lowercases the package id in the registration URL' {
            Mock Test-Path                { return $false }
            Mock Get-FileHash             { return [pscustomobject]@{ Hash = $script:KnownHashHex } }
            Mock Invoke-WebRequest        { }
            Mock Invoke-RestMethod        {
                return [pscustomobject]@{
                    packageHash          = $script:KnownHashBase64
                    packageHashAlgorithm = 'SHA512'
                }
            }
            Mock Invoke-DotnetNugetVerify { return [pscustomobject]@{ ExitCode = 0; Output = '' } }
            Mock Move-Item                { }
            Mock Set-Content              { }
            Mock Remove-Item              { }

            $vm = New-TestVm -Tools @((New-ToolEntry 'Pkg.Mixed.Case' '1.0.0'))
            Invoke-DotnetToolAcquisition -Vm $vm -CacheDir 'C:\VHDs'

            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Uri -eq 'https://api.nuget.org/v3/registration5-semver1/pkg.mixed.case/1.0.0.json'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'SHA-512 mismatch on cache miss' {
    # ------------------------------------------------------------------

        It 'throws naming both hashes, deletes temp file, writes no lockfile' {
            Mock Test-Path                { return $false }
            # File hashes to something else than what registration says.
            Mock Get-FileHash             { return [pscustomobject]@{ Hash = ('BB' * 64) } }
            Mock Invoke-WebRequest        { }
            Mock Invoke-RestMethod        {
                return [pscustomobject]@{
                    packageHash          = $script:KnownHashBase64
                    packageHashAlgorithm = 'SHA512'
                }
            }
            Mock Invoke-DotnetNugetVerify { throw 'must not verify on hash mismatch' }
            Mock Set-Content              { }
            Mock Move-Item                { }
            Mock Remove-Item              { }

            $vm  = New-TestVm -Tools @((New-ToolEntry 'pkg.a' '1.0.0'))
            $err = $null
            try { Invoke-DotnetToolAcquisition -Vm $vm -CacheDir 'C:\VHDs' }
            catch { $err = $_ }

            $err            | Should -Not -BeNullOrEmpty
            $err.ToString() | Should -Match $script:KnownHashHex
            $err.ToString() | Should -Match ('BB' * 64)

            Should -Invoke Invoke-DotnetNugetVerify -Times 0
            Should -Invoke Set-Content              -Times 0
            Should -Invoke Move-Item                -Times 0
            Should -Invoke Remove-Item              -Times 1 -ParameterFilter {
                $Path -match '\.downloading$'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'registration metadata missing packageHash' {
    # ------------------------------------------------------------------

        It 'throws with a diagnostic naming the package' {
            Mock Test-Path         { return $false }
            Mock Get-FileHash      { return [pscustomobject]@{ Hash = $script:KnownHashHex } }
            Mock Invoke-WebRequest { }
            Mock Invoke-RestMethod {
                return [pscustomobject]@{ packageHashAlgorithm = 'SHA512' }
            }
            Mock Remove-Item       { }
            Mock Set-Content       { }

            $vm = New-TestVm -Tools @((New-ToolEntry 'pkg.a' '1.0.0'))
            { Invoke-DotnetToolAcquisition -Vm $vm -CacheDir 'C:\VHDs' } |
                Should -Throw -ExpectedMessage '*pkg.a@1.0.0*missing packageHash*'

            Should -Invoke Set-Content -Times 0
        }
    }

    # ------------------------------------------------------------------
    Context 'dotnet nuget verify non-zero exit' {
    # ------------------------------------------------------------------

        It 'throws surfacing the verifier output, writes no lockfile' {
            Mock Test-Path                { return $false }
            Mock Get-FileHash             { return [pscustomobject]@{ Hash = $script:KnownHashHex } }
            Mock Invoke-WebRequest        { }
            Mock Invoke-RestMethod        {
                return [pscustomobject]@{
                    packageHash          = $script:KnownHashBase64
                    packageHashAlgorithm = 'SHA512'
                }
            }
            Mock Invoke-DotnetNugetVerify {
                return [pscustomobject]@{
                    ExitCode = 1
                    Output   = 'NU3008: signature mismatch'
                }
            }
            Mock Set-Content { }
            Mock Move-Item   { }
            Mock Remove-Item { }

            $vm = New-TestVm -Tools @((New-ToolEntry 'pkg.a' '1.0.0'))
            { Invoke-DotnetToolAcquisition -Vm $vm -CacheDir 'C:\VHDs' } |
                Should -Throw -ExpectedMessage '*NU3008*'

            Should -Invoke Set-Content -Times 0
            Should -Invoke Move-Item   -Times 0
        }
    }

    # ------------------------------------------------------------------
    Context 'multiple entries: stamping is additive' {
    # ------------------------------------------------------------------

        It 'records every entry under _dotnetToolNupkgPaths' {
            Mock Test-Path                { return $false }
            Mock Get-FileHash             { return [pscustomobject]@{ Hash = $script:KnownHashHex } }
            Mock Invoke-WebRequest        { }
            Mock Invoke-RestMethod        {
                return [pscustomobject]@{
                    packageHash          = $script:KnownHashBase64
                    packageHashAlgorithm = 'SHA512'
                }
            }
            Mock Invoke-DotnetNugetVerify { return [pscustomobject]@{ ExitCode = 0; Output = '' } }
            Mock Set-Content              { }
            Mock Move-Item                { }
            Mock Remove-Item              { }

            $vm = New-TestVm -Tools @(
                (New-ToolEntry 'pkg.a' '1.0.0'),
                (New-ToolEntry 'pkg.b' '2.3.4')
            )
            Invoke-DotnetToolAcquisition -Vm $vm -CacheDir 'C:\VHDs'

            $vm._dotnetToolNupkgPaths.Count | Should -Be 2
            $vm._dotnetToolNupkgPaths['pkg.a@1.0.0'] |
                Should -Be 'C:\VHDs\dotnet-tool-pkg.a-1.0.0.nupkg'
            $vm._dotnetToolNupkgPaths['pkg.b@2.3.4'] |
                Should -Be 'C:\VHDs\dotnet-tool-pkg.b-2.3.4.nupkg'
        }
    }
}
