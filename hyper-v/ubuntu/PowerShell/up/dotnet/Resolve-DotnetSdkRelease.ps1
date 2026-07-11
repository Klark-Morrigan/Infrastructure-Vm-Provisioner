<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    Invoke-DotnetSdkAcquisition.ps1.
#>

# ---------------------------------------------------------------------------
# Resolve-DotnetSdkRelease
#   Translates a user-supplied .NET SDK version granularity (e.g. "10",
#   "10.0", or "10.0.100") into a concrete
#   { ResolvedVersion, Sha512, DownloadUrl, SourceUrl } record by querying
#   Microsoft's release-metadata channel feed.
#
#   Pure helper: no disk writes, no caching, no lockfile reads. Lives in
#   its own file so the resolution logic stays a self-contained unit.
#
#   The HTTP call is delegated to Invoke-DotnetSdkReleasesJson below.
#   Wrapping it in a separate function isolates the single outbound HTTP
#   call behind one named boundary, keeping this resolver pure parsing
#   logic.
# ---------------------------------------------------------------------------

# Microsoft's release-metadata host. Constant rather than literal so the
# message in surfaced errors stays in sync if the host ever moves.
$script:DotnetSdkReleasesHost =
    'https://builds.dotnet.microsoft.com/dotnet/release-metadata'

# The linux-x64 SDK file is identified by the 'rid' field on each file
# entry inside an sdks[] record. Hardcoded per the v1 architecture scope
# documented in problem.md (out-of-scope: ARM/aarch64).
$script:DotnetSdkLinuxRid = 'linux-x64'

function Get-DotnetSdkReleasesUrl {
    # Centralised so the resolver and its error messages reference the
    # same URL string.
    param([Parameter(Mandatory)] [string] $Channel)
    return "$script:DotnetSdkReleasesHost/$Channel/releases.json"
}

function Invoke-DotnetSdkReleasesJson {
    # Thin wrapper around Invoke-RestMethod for the releases.json feed.
    # Isolates the lone network call behind one named boundary so the
    # resolver above stays pure parsing logic with no direct HTTP
    # dependency. Wrapped in Invoke-WithRetry with the transient-network
    # strategy so DNS / connectivity blips do not fail a provision run;
    # 4xx responses (e.g. an unknown channel) propagate immediately.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Channel)

    $uri = Get-DotnetSdkReleasesUrl -Channel $Channel

    return Invoke-WithRetry `
        -OperationName ".NET releases.json lookup (channel $Channel)" `
        -RetryStrategy (New-TransientNetworkRetryStrategy) `
        -ScriptBlock { Invoke-RestMethod -Uri $uri -UseBasicParsing }
}

function Get-DotnetSdkLinuxX64File {
    # Picks the linux-x64 .tar.gz entry from an sdk record's files[].
    # Throws with the SDK version in the message when the architecture
    # is absent, so callers see *which* SDK is the offender rather than
    # a generic "no binary found" error.
    param(
        [Parameter(Mandatory)] $Sdk,
        [Parameter(Mandatory)] [string] $Channel
    )

    $file = @($Sdk.files) | Where-Object {
        $_.rid -eq $script:DotnetSdkLinuxRid -and $_.name -like '*.tar.gz'
    } | Select-Object -First 1

    if ($null -eq $file) {
        throw (
            "Resolve-DotnetSdkRelease: SDK '$($Sdk.version)' on channel " +
            "'$Channel' has no '$($script:DotnetSdkLinuxRid)' .tar.gz file " +
            "in releases.json."
        )
    }
    return $file
}

function Resolve-DotnetSdkRelease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Channel,
        [Parameter(Mandatory)] [string] $RequestedVersion
    )

    # ------------------------------------------------------------------
    # Validate the requested-version shape up-front. Assert-DotnetSdkField
    # enforces the same regex upstream, but the resolver may be called by
    # future tools without going through schema validation; failing fast
    # here keeps the API contract explicit.
    # ------------------------------------------------------------------
    $isExact = $false
    if ($RequestedVersion -match '^\d+$' -or
        $RequestedVersion -match '^\d+\.\d+$') {
        $isExact = $false
    }
    elseif ($RequestedVersion -match '^\d+\.\d+\.\d+$') {
        $isExact = $true
    }
    else {
        throw (
            "Resolve-DotnetSdkRelease: version '$RequestedVersion' is not " +
            "a recognised granularity. Use '10', '10.0' or '10.0.100'."
        )
    }

    # ------------------------------------------------------------------
    # Fetch. The wrapper surfaces network failures with the channel URL
    # in the message so the operator can spot a typo'd channel.
    # ------------------------------------------------------------------
    $sourceUrl = Get-DotnetSdkReleasesUrl -Channel $Channel
    try {
        $feed = Invoke-DotnetSdkReleasesJson -Channel $Channel
    }
    catch {
        throw (
            "Resolve-DotnetSdkRelease: failed to fetch '$sourceUrl': $_"
        )
    }

    # ------------------------------------------------------------------
    # Decide which SDK version we are looking for. Major / major.minor
    # both defer to the feed's own 'latest-sdk' string, which is the
    # contract Microsoft publishes for "newest released SDK on this
    # channel". Exact requests use the requested string directly.
    # ------------------------------------------------------------------
    # Read 'latest-sdk' via PSObject.Properties rather than dotted access
    # so a feed that omits the field surfaces as a clean throw below
    # rather than a strict-mode PropertyNotFoundStrict exception.
    $latestSdkProp = $feed.PSObject.Properties['latest-sdk']
    $targetVersion = if ($isExact) {
        $RequestedVersion
    } elseif ($null -ne $latestSdkProp) {
        $latestSdkProp.Value
    } else {
        $null
    }

    if ([string]::IsNullOrWhiteSpace($targetVersion)) {
        throw (
            "Resolve-DotnetSdkRelease: channel '$Channel' feed at " +
            "'$sourceUrl' has no 'latest-sdk' field; cannot resolve " +
            "request '$RequestedVersion'."
        )
    }

    # ------------------------------------------------------------------
    # Scan releases[].sdks[] for the target version. The plural 'sdks'
    # list is the comprehensive one (the singular 'sdk' field is just a
    # convenience alias for releases[i].sdks[0]); scanning the plural
    # list means we find side-by-side SDKs published in the same
    # release entry.
    # Initialise as a real array first so .Count works even when one
    # match comes through (PowerShell unwraps single-element pipelines).
    # ------------------------------------------------------------------
    $availableVersions = @()
    $matchedSdk       = $null
    foreach ($release in @($feed.releases)) {
        foreach ($sdk in @($release.sdks)) {
            if ($null -eq $sdk -or [string]::IsNullOrWhiteSpace($sdk.version)) {
                continue
            }
            $availableVersions += $sdk.version
            if ($sdk.version -eq $targetVersion) {
                $matchedSdk = $sdk
                break
            }
        }
        if ($null -ne $matchedSdk) { break }
    }

    if ($null -eq $matchedSdk) {
        # ,@() prevents the outer string concatenation from unrolling
        # an empty available-versions list into the literal '$null'.
        $available = ($availableVersions | Sort-Object -Unique) -join ', '
        throw (
            "Resolve-DotnetSdkRelease: SDK version '$targetVersion' " +
            "(requested '$RequestedVersion') not found in channel " +
            "'$Channel'. Available SDKs: $available."
        )
    }

    $file = Get-DotnetSdkLinuxX64File -Sdk $matchedSdk -Channel $Channel

    # PSCustomObject (not hashtable) so the downstream consumers in
    # Invoke-DotnetSdkAcquisition can use member access without
    # worrying about strict-mode key-missing throws on a typo.
    return [pscustomobject]@{
        ResolvedVersion = $matchedSdk.version
        Sha512          = $file.hash
        DownloadUrl     = $file.url
        SourceUrl       = $sourceUrl
    }
}
