<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    Invoke-JdkAcquisition.ps1.
#>

# ---------------------------------------------------------------------------
# Resolve-AdoptiumRelease
#   Translates a user-supplied version granularity into a concrete
#   { ResolvedVersion, Sha256, DownloadUrl, ArchiveName } hashtable by
#   querying the Adoptium v3 feature_releases endpoint.
#
#   Pure helper: no disk writes, no caching, no lockfile reads. Lives in
#   its own file so the resolution logic stays a self-contained unit.
#
#   The Adoptium HTTP call is delegated to Invoke-AdoptiumFeatureReleases
#   below. Wrapping the call in a separate function isolates the single
#   outbound HTTP call behind one named boundary, keeping this resolver
#   pure parsing logic.
# ---------------------------------------------------------------------------

function Invoke-AdoptiumFeatureReleases {
    # Thin wrapper around Invoke-RestMethod for the GA feature_releases
    # endpoint. Isolates the lone network call behind one named boundary
    # so the resolver above stays pure parsing logic with no direct HTTP
    # dependency.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int] $Major,
        [Parameter(Mandatory)] [int] $PageSize
    )

    $uri = (
        "https://api.adoptium.net/v3/assets/feature_releases/$Major/ga" +
        "?architecture=x64&image_type=jdk&os=linux" +
        "&page_size=$PageSize&sort_order=DESC"
    )

    # Wrapped in Invoke-WithRetry with the transient-network strategy so
    # transient DNS / connectivity blips against api.adoptium.net do not
    # fail a provision run. 4xx responses (e.g. an unknown major version)
    # propagate immediately - see New-TransientNetworkRetryStrategy.
    return Invoke-WithRetry `
        -OperationName "Adoptium feature_releases lookup (major $Major)" `
        -RetryStrategy (New-TransientNetworkRetryStrategy) `
        -ScriptBlock { Invoke-RestMethod -Uri $uri -UseBasicParsing }
}

function Resolve-AdoptiumRelease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Vendor,
        [Parameter(Mandatory)] [string] $Version
    )

    # Vendor gate stays here even though Assert-JavaDevKitField already
    # enforces 'temurin' upstream. The resolver may be called by future
    # tools without going through schema validation; failing fast here
    # keeps the API contract explicit.
    if ($Vendor -ne 'temurin') {
        throw (
            "Resolve-AdoptiumRelease: vendor '$Vendor' is not supported " +
            "(only 'temurin' in v1)."
        )
    }

    # ------------------------------------------------------------------
    # Parse the requested version into a major plus optional constraints.
    # Each $null slot below means 'do not filter on this field'.
    # ------------------------------------------------------------------
    $minor    = $null
    $security = $null
    $build    = $null

    if ($Version -match '^(\d+)$') {
        $major = [int]$Matches[1]
        # Major-only: trust sort_order=DESC and take the single newest.
        $pageSize = 1
    }
    elseif ($Version -match '^(\d+)\.(\d+)$') {
        $major = [int]$Matches[1]
        $minor = [int]$Matches[2]
        $pageSize = 50
    }
    elseif ($Version -match '^(\d+)\.(\d+)\.(\d+)$') {
        $major    = [int]$Matches[1]
        $minor    = [int]$Matches[2]
        $security = [int]$Matches[3]
        $pageSize = 50
    }
    elseif ($Version -match '^(\d+)\.(\d+)\.(\d+)\+(\d+)$') {
        $major    = [int]$Matches[1]
        $minor    = [int]$Matches[2]
        $security = [int]$Matches[3]
        $build    = [int]$Matches[4]
        $pageSize = 50
    }
    else {
        throw (
            "Resolve-AdoptiumRelease: version '$Version' is not a recognised " +
            "granularity. Use '21', '21.0', '21.0.5' or '21.0.5+11'."
        )
    }

    # ------------------------------------------------------------------
    # Fetch and filter. Initialise as a real array first so the [0]
    # indexing below works even when the API returns a single object
    # (PowerShell unwraps single-element pipelines unless forced).
    # ------------------------------------------------------------------
    $releases = @(Invoke-AdoptiumFeatureReleases -Major $major -PageSize $pageSize)

    if ($releases.Count -eq 0) {
        throw (
            "Resolve-AdoptiumRelease: Adoptium returned no GA releases for " +
            "major $major (requested '$Version')."
        )
    }

    # Build matches as a real array up-front; relying on the pipeline to
    # produce one would yield $null for single matches and break .Count.
    $candidates = @()
    foreach ($release in $releases) {
        $vd = $release.version_data
        if ($null -ne $minor    -and $vd.minor    -ne $minor)    { continue }
        if ($null -ne $security -and $vd.security -ne $security) { continue }
        if ($null -ne $build    -and $vd.build    -ne $build)    { continue }
        $candidates += $release
    }

    if ($candidates.Count -eq 0) {
        throw (
            "Resolve-AdoptiumRelease: no Adoptium GA build matches version " +
            "'$Version'. Check the requested version against " +
            "https://adoptium.net/temurin/releases/."
        )
    }

    # API was queried with sort_order=DESC, so candidate ordering is
    # already newest-first. Take the head.
    $pick   = $candidates[0]
    $binary = @($pick.binaries)[0]

    if ($null -eq $binary -or $null -eq $binary.package) {
        throw (
            "Resolve-AdoptiumRelease: release '$($pick.release_name)' has " +
            "no x64/linux/jdk binary in the Adoptium response."
        )
    }

    # Reconstruct the concrete version from the structured numeric fields
    # rather than passing through version_data.openjdk_version. For LTS
    # feature releases Adoptium adorns openjdk_version with a vendor tag
    # (e.g. '21.0.11+10-LTS'), and some lines carry an interim-patch
    # component ('11.0.16.1+1'). Downstream consumers - notably the
    # Ansible jdk role's granularity assertion and its build filter -
    # accept only the canonical 'major.minor.security+build' shape, so
    # emit exactly that. The same numeric fields are already trusted for
    # candidate filtering above, so this introduces no new dependency.
    $vd = $pick.version_data
    return @{
        ResolvedVersion = "$($vd.major).$($vd.minor).$($vd.security)+$($vd.build)"
        Sha256          = $binary.package.checksum
        DownloadUrl     = $binary.package.link
        ArchiveName     = $binary.package.name
    }
}
