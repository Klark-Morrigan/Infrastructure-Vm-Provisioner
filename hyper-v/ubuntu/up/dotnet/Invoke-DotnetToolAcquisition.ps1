<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1 (host-side, before any VM-bound .nupkg streaming).
#>

# ---------------------------------------------------------------------------
# Invoke-DotnetToolAcquisition
#   Host-side prefetch for each `dotnetTools` entry on a VM definition.
#   The host is the only machine that talks to nuget.org; every VM
#   consumes pre-verified bytes from the per-host cache (problem.md
#   Option B). The acquirer:
#
#     1. Computes cache paths under $CacheDir:
#          dotnet-tool-{id}-{version}.nupkg
#          dotnet-tool-{id}-{version}.lock.json
#     2. Cache hit when both files exist AND the lockfile's recorded
#        SHA-512 matches the on-disk .nupkg. Otherwise re-fetch.
#     3. Downloads the .nupkg from
#          https://www.nuget.org/api/v2/package/{id}/{version}
#        into a sibling temp file under $CacheDir, then fetches the
#        registration leaf metadata at
#          https://api.nuget.org/v3/registration5-semver1/{idLower}/{version}.json
#        and pulls `packageHash` (SHA-512) + `packageHashAlgorithm` from
#        the response. Missing fields throw - the registration is the
#        authoritative pin source.
#     4. Verifies the downloaded file's SHA-512 against the registration
#        hash. Mismatch throws naming both hashes and removes the temp
#        file so the next run is a fresh cache miss.
#     5. Verifies the nuget.org repo countersignature by invoking
#          dotnet nuget verify --all --configfile <pinned config>
#        against the trusted-signers config checked in alongside this
#        script. Non-zero exit throws and surfaces the verifier stderr.
#     6. Atomically renames the temp file into the final cache path and
#        writes the lockfile sidecar (schema below).
#     7. Stamps $Vm._dotnetToolNupkgPaths (a hashtable keyed by
#        "{id}@{version}") with the absolute cache path so the
#        DotnetToolsProvider in Phase B can stream the bytes to the VM
#        without re-acquiring.
#
#   Lockfile schema:
#     { id, version, nupkg, sha512, source, acquiredAt }
#   Absent/empty `dotnetTools` -> early return. No SSH; pure host I/O.
# ---------------------------------------------------------------------------

function Invoke-DotnetToolAcquisition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Vm,

        [Parameter(Mandatory)]
        [string] $CacheDir
    )

    # ------------------------------------------------------------------
    # Absent / null / [] - operator's "ensure none" signal. Nothing to
    # prefetch; the reconciler's uninstall path consumes no .nupkg.
    # Safe to call unconditionally from the dispatcher.
    # ------------------------------------------------------------------
    $toolsProp = $Vm.PSObject.Properties['dotnetTools']
    if ($null -eq $toolsProp -or $null -eq $toolsProp.Value) {
        return
    }
    $entries = @($toolsProp.Value)
    if ($entries.Count -eq 0) {
        return
    }

    Write-Host ""
    Write-Host "--- .NET tools acquisition: $($Vm.vmName) ---" -ForegroundColor Cyan

    # ------------------------------------------------------------------
    # Path to the pinned trusted-signers config. Resolved once - the
    # config is checked in next to this script.
    # ------------------------------------------------------------------
    $trustedSignersConfig = Join-Path $PSScriptRoot 'nuget-trusted-signers.config'

    # ------------------------------------------------------------------
    # Append-style stamp across entries. If the property is already set
    # from a prior call (defensive - one provision should call us once),
    # extend it rather than replace, so the dispatcher can never
    # accidentally lose paths between entries.
    # ------------------------------------------------------------------
    $existing = $Vm.PSObject.Properties['_dotnetToolNupkgPaths']
    $nupkgPaths = if ($null -ne $existing -and $existing.Value -is [hashtable]) {
        $existing.Value
    } else {
        @{}
    }

    foreach ($entry in $entries) {
        $id      = $entry.id
        $version = $entry.version
        $idLower = $id.ToLowerInvariant()

        $nupkgPath = Join-Path $CacheDir "dotnet-tool-$id-$version.nupkg"
        $lockPath  = Join-Path $CacheDir "dotnet-tool-$id-$version.lock.json"
        $sourceUrl = "https://www.nuget.org/api/v2/package/$id/$version"

        $cacheHit = $false
        if ((Test-Path $lockPath) -and (Test-Path $nupkgPath)) {
            $lock       = Get-Content -Path $lockPath -Raw | ConvertFrom-Json
            $actualHash = (Get-FileHash -Path $nupkgPath -Algorithm SHA512).Hash
            if ($actualHash -ieq $lock.sha512) {
                $cacheHit = $true
                Write-Host "  Cache hit: $nupkgPath" -ForegroundColor Green
            }
        }

        if (-not $cacheHit) {
            # ----------------------------------------------------------
            # Cache miss (or hash drift). Download to a temp file first
            # so a partial/corrupt fetch never poisons the final path;
            # the atomic rename in step 7 is the commit point.
            # ----------------------------------------------------------
            $tempPath = "$nupkgPath.downloading"
            Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue

            Write-Host "  Cache miss - acquiring $id@$version ..."
            Write-Host "    From: $sourceUrl"

            Invoke-WithRetry `
                -OperationName ".NET tool .nupkg download ($id@$version)" `
                -RetryStrategy (New-TransientNetworkRetryStrategy) `
                -ScriptBlock {
                    Invoke-WebRequest -Uri $sourceUrl `
                                      -OutFile $tempPath `
                                      -UseBasicParsing
                }

            # ----------------------------------------------------------
            # Registration leaf carries the authoritative SHA-512 and
            # algorithm name. Both fields are required; absence is a
            # protocol error, not a transient failure.
            # ----------------------------------------------------------
            $registrationUrl =
                "https://api.nuget.org/v3/registration5-semver1/$idLower/$version.json"
            $registration = Invoke-WithRetry `
                -OperationName ".NET tool registration metadata ($id@$version)" `
                -RetryStrategy (New-TransientNetworkRetryStrategy) `
                -ScriptBlock {
                    Invoke-RestMethod -Uri $registrationUrl -UseBasicParsing
                }

            # Probe via PSObject.Properties so a missing field reads as
            # $null instead of throwing under StrictMode.
            $hashProp = $registration.PSObject.Properties['packageHash']
            $algoProp = $registration.PSObject.Properties['packageHashAlgorithm']
            $expectedHash = if ($hashProp) { $hashProp.Value } else { $null }
            $hashAlgo     = if ($algoProp) { $algoProp.Value } else { $null }
            if ([string]::IsNullOrEmpty($expectedHash) -or
                [string]::IsNullOrEmpty($hashAlgo)) {
                Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue
                throw (
                    "Registration metadata for '$id@$version' at " +
                    "'$registrationUrl' is missing packageHash or " +
                    "packageHashAlgorithm. Cannot verify download."
                )
            }
            if ($hashAlgo -ine 'SHA512') {
                Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue
                throw (
                    "Registration metadata for '$id@$version' advertises " +
                    "packageHashAlgorithm '$hashAlgo'; only SHA512 is " +
                    "supported."
                )
            }

            # ----------------------------------------------------------
            # SHA-512 compare. Registration hashes are base64-encoded,
            # Get-FileHash returns uppercase hex - normalise both sides
            # to the same hex representation before comparing.
            # ----------------------------------------------------------
            $actualHashHex   = (Get-FileHash -Path $tempPath -Algorithm SHA512).Hash
            $expectedHashHex = ConvertFrom-NugetHashBase64 -Base64 $expectedHash
            if ($actualHashHex -ine $expectedHashHex) {
                Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue
                throw (
                    "SHA-512 mismatch for '$id@$version'. Registration " +
                    "advertised '$expectedHashHex' but download from " +
                    "'$sourceUrl' hashed to '$actualHashHex'."
                )
            }

            # ----------------------------------------------------------
            # Repo countersignature check. Author signatures are out of
            # scope for v1 (problem.md decision 2). --configfile pins
            # the trust policy to the checked-in fingerprint so the
            # verifier cannot fall back to a host-level config.
            # ----------------------------------------------------------
            $verifyResult = Invoke-DotnetNugetVerify `
                                -NupkgPath  $tempPath `
                                -ConfigPath $trustedSignersConfig
            if ($verifyResult.ExitCode -ne 0) {
                Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue
                throw (
                    "dotnet nuget verify failed for '$id@$version' (exit " +
                    "$($verifyResult.ExitCode)). Verifier output: " +
                    $verifyResult.Output
                )
            }

            # ----------------------------------------------------------
            # Commit point. Move-Item -Force on the same volume is the
            # closest PowerShell gets to atomic rename; the temp file
            # lives under $CacheDir so we never cross volumes.
            # ----------------------------------------------------------
            Move-Item -Path $tempPath -Destination $nupkgPath -Force

            $lockObject = [pscustomobject]@{
                id         = $id
                version    = $version
                nupkg      = "dotnet-tool-$id-$version.nupkg"
                sha512     = $actualHashHex
                source     = $sourceUrl
                acquiredAt = (Get-Date).ToUniversalTime().ToString('o')
            }
            $lockObject | ConvertTo-Json | Set-Content -Path $lockPath -Encoding UTF8

            Write-Host "  [OK] $id@$version cached: $nupkgPath" -ForegroundColor Green
        }

        $nupkgPaths["$id@$version"] = $nupkgPath
    }

    Add-Member -InputObject $Vm -MemberType NoteProperty `
               -Name '_dotnetToolNupkgPaths' -Value $nupkgPaths -Force
}

# ---------------------------------------------------------------------------
# ConvertFrom-NugetHashBase64
#   Registration metadata reports SHA-512 hashes as base64. Get-FileHash
#   returns uppercase hex. This helper bridges the encodings so the
#   compare in step 4 is a straight string match.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Invoke-DotnetNugetVerify
#   Thin wrapper around `dotnet nuget verify` so the acquirer's verify
#   step is a single mockable function instead of a raw native-exec.
#   Returns { ExitCode, Output } - the caller decides how to surface
#   failures.
# ---------------------------------------------------------------------------
function Invoke-DotnetNugetVerify {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $NupkgPath,
        [Parameter(Mandatory)] [string] $ConfigPath
    )

    $output = & dotnet nuget verify $NupkgPath `
                  --all `
                  --configfile $ConfigPath 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = ($output -join [Environment]::NewLine)
    }
}

function ConvertFrom-NugetHashBase64 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Base64
    )

    $bytes = [System.Convert]::FromBase64String($Base64)
    return ([System.BitConverter]::ToString($bytes)).Replace('-', '').ToUpperInvariant()
}
