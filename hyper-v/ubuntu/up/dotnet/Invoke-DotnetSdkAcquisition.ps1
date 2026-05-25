<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1 after Resolve-DotnetSdkRelease.ps1 is loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-DotnetSdkAcquisition
#   Host-side prefetch for the .NET SDK tarball: resolves the requested
#   version against Microsoft's release-metadata feed, downloads it,
#   verifies its SHA-512, and stamps a sidecar lockfile so subsequent
#   provisionings of the same VM are deterministic and offline-safe.
#
#   Cache layout (per CacheDir, typically Vm.vhdPath):
#     dotnet-sdk-{resolvedVersion}-linux-x64.tar.gz   - the archive
#     dotnet-sdk-{requestedVersion}-linux-x64.lock.json - the pin
#
#   The lockfile is keyed by the *requested* version so two VMs asking
#   for "10.0" share one cache slot. The tarball is keyed by the
#   *resolved* version so two distinct requests that happen to resolve
#   to the same SDK share a single tarball on disk. The lockfile maps
#   between them and is the authoritative "what this slot committed to"
#   record - the resolver is not re-invoked once the lockfile exists.
#
#   On return, $Vm._dotnetSdkTarballPath and $Vm._dotnetSdkResolvedVersion
#   are set via Add-Member. The post-provisioning reconciler's
#   DotnetSdkProvider (composed in a later step) forwards these to its
#   Install-Version dispatch, mirroring how Invoke-JdkAcquisition feeds
#   the JdkProvider.
# ---------------------------------------------------------------------------

function Invoke-DotnetSdkAcquisition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Vm,

        [Parameter(Mandatory)]
        [string] $CacheDir
    )

    # ------------------------------------------------------------------
    # Empty / absent dotnetSdk means the operator's intent is "ensure
    # none" - nothing to prefetch. The reconciler's uninstall path needs
    # no tarball. Returning silently keeps this safe to call
    # unconditionally from the dispatcher (Step 15 still guards for
    # symmetry with the JDK branch, but the defence-in-depth here means
    # a future caller cannot accidentally trigger a resolver call on an
    # ensure-none VM).
    # ------------------------------------------------------------------
    $dotnetSdkProp = $Vm.PSObject.Properties['dotnetSdk']
    if ($null -eq $dotnetSdkProp -or
        $null -eq $dotnetSdkProp.Value -or
        @($dotnetSdkProp.Value).Count -eq 0) {
        return
    }

    Write-Host ""
    Write-Host "--- .NET SDK acquisition: $($Vm.vmName) ---" -ForegroundColor Cyan

    # Validator (Assert-DotnetSdkField) caps the list to length 1 and
    # accepts both scalar and list shapes; normalise to a single entry
    # here so the rest of the function is shape-free.
    $sdk = if ($dotnetSdkProp.Value -is [array]) {
        @($dotnetSdkProp.Value)[0]
    } else {
        $dotnetSdkProp.Value
    }
    $channel          = $sdk.channel
    $requestedVersion = $sdk.version

    # ------------------------------------------------------------------
    # Cache paths. CacheDir is guaranteed to exist by the upstream disk-
    # acquisition step that runs before this acquirer in provision.ps1;
    # no directory creation here.
    # ------------------------------------------------------------------
    $lockKey  = "dotnet-sdk-$requestedVersion-linux-x64"
    $lockPath = Join-Path $CacheDir "$lockKey.lock.json"

    if (Test-Path $lockPath) {
        # --------------------------------------------------------------
        # Lockfile present - cache hit or hash-mismatch recovery. The
        # lockfile is authoritative for resolvedVersion and the pinned
        # download URL; the resolver is not re-invoked.
        # --------------------------------------------------------------
        $lock            = Get-Content -Path $lockPath -Raw | ConvertFrom-Json
        $resolvedVersion = $lock.resolvedVersion
        $tarballPath     = Join-Path $CacheDir "dotnet-sdk-$resolvedVersion-linux-x64.tar.gz"

        $tarballOk = $false
        if (Test-Path $tarballPath) {
            $actualHash = (Get-FileHash -Path $tarballPath -Algorithm SHA512).Hash
            if ($actualHash -ieq $lock.sha512) {
                $tarballOk = $true
            }
        }

        if ($tarballOk) {
            Write-Host "  Cache hit: $tarballPath" -ForegroundColor Green
        }
        else {
            # ----------------------------------------------------------
            # One retry from the pinned source URL. A second mismatch
            # throws - upstream is serving different bytes for the same
            # URL and operator intervention is needed (delete the
            # lockfile to force a fresh resolve).
            # ----------------------------------------------------------
            Write-Warning (
                "dotnet SDK cache retry: tarball missing or hash mismatch " +
                "for '$lockKey'. Re-downloading from pinned source."
            )

            try {
                Invoke-WithRetry `
                    -OperationName ".NET SDK re-download ($lockKey)" `
                    -RetryStrategy (New-TransientNetworkRetryStrategy) `
                    -ScriptBlock {
                        Invoke-WebRequest -Uri $lock.sourceUrl `
                                          -OutFile $tarballPath `
                                          -UseBasicParsing
                    }
            }
            catch {
                throw (
                    "Re-download failed from pinned source " +
                    "'$($lock.sourceUrl)': $_. Microsoft may have rotated " +
                    "the URL. Delete '$lockPath' to force re-resolution " +
                    "against the live release-metadata feed on the next run."
                )
            }

            $newHash = (Get-FileHash -Path $tarballPath -Algorithm SHA512).Hash
            if ($newHash -ine $lock.sha512) {
                throw (
                    "Re-download hash mismatch for '$lockKey'. Lockfile " +
                    "expected '$($lock.sha512)' but the redownload from " +
                    "'$($lock.sourceUrl)' produced '$newHash'. Upstream " +
                    "served different bytes for the same URL."
                )
            }

            Write-Host "  [OK] Re-download verified: $tarballPath" `
                -ForegroundColor Green
        }
    }
    else {
        # --------------------------------------------------------------
        # True cache miss: resolve against the live feed, download,
        # verify, then write the lockfile. Lockfile is written only
        # after a successful hash check so an aborted run does not
        # leave a stale pin behind.
        # --------------------------------------------------------------
        Write-Host "  Cache miss - resolving channel $channel ($requestedVersion) ..."
        $release = Resolve-DotnetSdkRelease `
            -Channel $channel `
            -RequestedVersion $requestedVersion

        $resolvedVersion = $release.ResolvedVersion
        $tarballPath     = Join-Path $CacheDir "dotnet-sdk-$resolvedVersion-linux-x64.tar.gz"

        Write-Host "  Downloading $resolvedVersion ..."
        Write-Host "    From: $($release.DownloadUrl)"
        Write-Host "    To  : $tarballPath"

        Invoke-WithRetry `
            -OperationName ".NET SDK tarball download ($lockKey)" `
            -RetryStrategy (New-TransientNetworkRetryStrategy) `
            -ScriptBlock {
                Invoke-WebRequest -Uri $release.DownloadUrl `
                                  -OutFile $tarballPath `
                                  -UseBasicParsing
            }

        $actualHash = (Get-FileHash -Path $tarballPath -Algorithm SHA512).Hash
        if ($actualHash -ine $release.Sha512) {
            # Remove the partial/corrupt tarball and skip the lockfile
            # write so the next run is a fresh cache miss.
            Remove-Item -Path $tarballPath -Force -ErrorAction SilentlyContinue
            throw (
                "Fresh download hash mismatch for '$lockKey'. Feed " +
                "advertised '$($release.Sha512)' but the downloaded file " +
                "hashed to '$actualHash'."
            )
        }

        # Lockfile schema: resolvedVersion, sha512, sourceUrl,
        # downloadedUtc. sourceUrl is the *download* URL (pinned binary
        # location), not the channel feed URL, so the re-download path
        # above can fetch the exact tarball without re-resolving.
        $lockObject = [pscustomobject]@{
            resolvedVersion = $release.ResolvedVersion
            sha512          = $release.Sha512
            sourceUrl       = $release.DownloadUrl
            downloadedUtc   = (Get-Date).ToUniversalTime().ToString('o')
        }
        $lockObject | ConvertTo-Json | Set-Content -Path $lockPath -Encoding UTF8

        Write-Host "  [OK] .NET SDK cached: $tarballPath" -ForegroundColor Green
    }

    # ------------------------------------------------------------------
    # Publish the cached artifact location and resolved version to the
    # VM object so the post-provisioning DotnetSdkProvider's
    # Install-Version scriptblock can forward them without recomputing.
    # ------------------------------------------------------------------
    Add-Member -InputObject $Vm -MemberType NoteProperty `
               -Name '_dotnetSdkTarballPath' -Value $tarballPath -Force
    Add-Member -InputObject $Vm -MemberType NoteProperty `
               -Name '_dotnetSdkResolvedVersion' -Value $resolvedVersion -Force
}
