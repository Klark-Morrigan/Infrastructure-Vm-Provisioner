<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    the Ansible slice's Stage-ToolchainArtifacts.ps1.
#>

# ---------------------------------------------------------------------------
# Resolve-PowerShellRelease
#   Translates a user-supplied version granularity into a concrete
#   { ResolvedVersion, Sha256, DownloadUrl, ArchiveName } hashtable by
#   querying the PowerShell/PowerShell GitHub releases API.
#
#   Sibling of Resolve-AdoptiumRelease / Resolve-DotnetSdkRelease - same
#   shape, same output contract, so the three stay easy to reason about
#   together and Stage-ToolchainArtifacts treats them uniformly.
#
#   Pure helper: no disk writes, no caching, no lockfile reads. Lives in
#   its own file so the resolution logic stays a self-contained unit.
#
#   Two outbound calls, each behind its own named boundary function below
#   (Invoke-PowerShellReleaseList / Invoke-PowerShellHashManifest), so this
#   resolver stays parsing logic with no direct HTTP dependency:
#     1. the releases list, to turn a loose pin into a concrete version;
#     2. the release's hashes.sha256 manifest, for the checksum the
#        staging step verifies the download against.
#
#   The checksum matters more here than the version resolution: the Ansible
#   powershell role composes its archive name from the version and pulls
#   from the host file server WITHOUT verifying anything, so this is the
#   only place the bytes are ever checked against upstream.
# ---------------------------------------------------------------------------

# GitHub returns releases newest-CREATED first, not highest-version first: a
# 7.5.x servicing release ships after a 7.6.x, so it appears earlier in the
# list. The resolver therefore sorts candidates by version itself and never
# trusts list order. One page of this size covers well over a year of
# releases across every supported line, which is ample for resolving a pin
# against currently-supported versions.
$script:PowerShellReleasePageSize = 100

# The asset that carries every asset's SHA-256 for a given release. Encoded
# UTF-16LE with a BOM (a Windows-authored file), which is why the manifest
# is fetched as bytes and decoded explicitly rather than left to
# Invoke-WebRequest's content-type guess.
$script:PowerShellHashManifestName = 'hashes.sha256'

function Invoke-PowerShellReleaseList {
    # Thin wrapper around Invoke-RestMethod for the releases endpoint.
    # Isolates one of the two network calls behind a named boundary so the
    # resolver above stays pure parsing logic.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int] $PageSize
    )

    $uri = (
        'https://api.github.com/repos/PowerShell/PowerShell/releases' +
        "?per_page=$PageSize"
    )

    # Wrapped in Invoke-WithRetry with the transient-network strategy so
    # transient DNS / connectivity blips against api.github.com do not fail
    # a staging run. 4xx responses propagate immediately - see
    # New-TransientNetworkRetryStrategy. Note an unauthenticated caller gets
    # 60 requests/hour here; the caller memoizes per unique pin so a fleet
    # sharing one version costs a single call.
    return Invoke-WithRetry `
        -OperationName 'GitHub PowerShell releases lookup' `
        -RetryStrategy (New-TransientNetworkRetryStrategy) `
        -ScriptBlock { Invoke-RestMethod -Uri $uri -UseBasicParsing }
}

function Invoke-PowerShellHashManifest {
    # Fetches a release's hashes.sha256 and returns it as text. The second
    # of the two network calls, behind its own boundary for the same reason.
    #
    # Decoding is explicit: the asset is UTF-16LE with a BOM, served as
    # application/octet-stream, so Invoke-WebRequest hands back a byte[].
    # Letting a default (UTF-8) decode run over those bytes would yield a
    # string with a NUL between every character and match nothing.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Url
    )

    $response = Invoke-WithRetry `
        -OperationName "PowerShell release hash manifest ($Url)" `
        -RetryStrategy (New-TransientNetworkRetryStrategy) `
        -ScriptBlock { Invoke-WebRequest -Uri $Url -UseBasicParsing }

    $content = $response.Content

    # Tolerate either shape rather than assuming one: a byte[] is what the
    # live endpoint returns, but a mocked or proxied response may already
    # be a string, and a decode attempt on a string would throw.
    $text = if ($content -is [byte[]]) {
        [System.Text.Encoding]::Unicode.GetString($content)
    }
    else {
        [string]$content
    }

    # Strip the BOM so the first line parses like every other line.
    return $text.TrimStart([char]0xFEFF)
}

function Resolve-PowerShellRelease {
    [CmdletBinding()]
    param(
        # A version pin at one of three granularities: '7' (newest stable
        # 7.x), '7.6' (newest stable on the 7.6 line), or '7.6.4' (that
        # exact release).
        [Parameter(Mandatory)] [string] $Version,

        # Spliced into the asset name. Matches the Ansible role's
        # powershell_architecture, and must agree with it - the role
        # re-derives the same name to pull by.
        [Parameter()] [string] $Architecture = 'x64'
    )

    # ------------------------------------------------------------------
    # Parse the requested version into a major plus optional constraints.
    # Each $null slot below means 'do not filter on this field'.
    # ------------------------------------------------------------------
    $minor = $null
    $patch = $null

    if ($Version -match '^(\d+)$') {
        $major = [int]$Matches[1]
    }
    elseif ($Version -match '^(\d+)\.(\d+)$') {
        $major = [int]$Matches[1]
        $minor = [int]$Matches[2]
    }
    elseif ($Version -match '^(\d+)\.(\d+)\.(\d+)$') {
        $major = [int]$Matches[1]
        $minor = [int]$Matches[2]
        $patch = [int]$Matches[3]
    }
    else {
        throw (
            "Resolve-PowerShellRelease: version '$Version' is not a " +
            "recognised granularity. Use '7', '7.6' or '7.6.4'."
        )
    }

    # ------------------------------------------------------------------
    # Fetch and filter. ConvertTo-Array, not a bare @(), is load-bearing:
    # Invoke-RestMethod writes a JSON array to the pipeline as a SINGLE
    # Object[] without enumerating it, so `@(Invoke-...)` collects ONE
    # element that is itself the whole array - .Count reads 1 and the
    # filter loop below iterates the array instead of the releases in it.
    # ConvertTo-Array normalizes both that shape and a single-object
    # response to a flat array.
    # ------------------------------------------------------------------
    $releases = ConvertTo-Array (
        Invoke-PowerShellReleaseList -PageSize $script:PowerShellReleasePageSize
    )

    if ($releases.Count -eq 0) {
        throw (
            'Resolve-PowerShellRelease: the GitHub releases endpoint ' +
            "returned no releases (requested '$Version')."
        )
    }

    # Build matches as a real array up-front; relying on the pipeline to
    # produce one would yield $null for single matches and break .Count.
    #
    # Previews and drafts are excluded unconditionally. A pin like '7'
    # must not silently resolve to a 7.7.0-preview build, and the
    # prerelease flag is upstream's own statement about which those are -
    # more reliable than pattern-matching the tag.
    $candidates = @()
    foreach ($release in $releases) {
        if ($release.prerelease -or $release.draft) { continue }

        # Tags are 'v<major>.<minor>.<patch>'. Anything else on this repo is
        # not a product release, so skip rather than fail the whole run.
        if ([string]$release.tag_name -notmatch '^v(\d+)\.(\d+)\.(\d+)$') {
            continue
        }

        if ([int]$Matches[1] -ne $major) { continue }
        if ($null -ne $minor -and [int]$Matches[2] -ne $minor) { continue }
        if ($null -ne $patch -and [int]$Matches[3] -ne $patch) { continue }

        $candidates += [pscustomobject]@{
            Release = $release
            # Cast for ordering: [version] compares numerically
            # component-by-component, so 7.6.10 sorts above 7.6.9 where a
            # string sort would not.
            Version = [version]$Matches[0].TrimStart('v')
        }
    }

    if ($candidates.Count -eq 0) {
        throw (
            "Resolve-PowerShellRelease: no stable PowerShell release " +
            "matches version '$Version'. Check the requested version " +
            'against https://github.com/PowerShell/PowerShell/releases.'
        )
    }

    # Highest version wins - list order is by creation date, not version
    # (see the page-size note above), so this sort is load-bearing.
    $pick            = ($candidates | Sort-Object -Property Version -Descending)[0]
    $resolvedVersion = $pick.Version.ToString()
    $archiveName     = "powershell-$resolvedVersion-linux-$Architecture.tar.gz"

    $assets       = ConvertTo-Array $pick.Release.assets
    $archiveAsset = $assets | Where-Object { $_.name -eq $archiveName } | Select-Object -First 1
    if ($null -eq $archiveAsset) {
        throw (
            "Resolve-PowerShellRelease: release " +
            "'$($pick.Release.tag_name)' has no asset named " +
            "'$archiveName'. Check that architecture '$Architecture' is " +
            'published for this version.'
        )
    }

    $hashAsset = $assets |
        Where-Object { $_.name -eq $script:PowerShellHashManifestName } |
        Select-Object -First 1
    if ($null -eq $hashAsset) {
        throw (
            "Resolve-PowerShellRelease: release " +
            "'$($pick.Release.tag_name)' publishes no " +
            "'$($script:PowerShellHashManifestName)' asset, so the " +
            'download cannot be checksum-verified. Refusing to stage an ' +
            'unverifiable artifact.'
        )
    }

    $sha256 = Get-PowerShellAssetHash `
        -ManifestText (Invoke-PowerShellHashManifest -Url $hashAsset.browser_download_url) `
        -AssetName    $archiveName

    return @{
        ResolvedVersion = $resolvedVersion
        Sha256          = $sha256
        DownloadUrl     = $archiveAsset.browser_download_url
        ArchiveName     = $archiveName
    }
}

# ---------------------------------------------------------------------------
# Get-PowerShellAssetHash
#   Extracts one asset's SHA-256 from a release's hashes.sha256 manifest.
#
#   Split out from the resolver so the parsing is testable without any
#   network mock, and because the manifest's format is a detail of the
#   upstream file rather than of release resolution.
#
#   Lines are sha256sum's binary form - '<64 hex> *<filename>' - one per
#   published asset of every platform, so the lookup is by exact name.
# ---------------------------------------------------------------------------
function Get-PowerShellAssetHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $ManifestText,
        [Parameter(Mandatory)] [string] $AssetName
    )

    foreach ($line in ($ManifestText -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

        # ' *' is sha256sum's binary-mode separator; ' ' alone is text mode.
        # Accept either so a change of mode upstream does not break parsing.
        if ($trimmed -match '^([0-9a-fA-F]{64})\s+\*?(.+)$') {
            if ($Matches[2].Trim() -eq $AssetName) {
                return $Matches[1].ToUpperInvariant()
            }
        }
    }

    throw (
        "Resolve-PowerShellRelease: the release hash manifest has no entry " +
        "for '$AssetName', so its checksum cannot be pinned. Refusing to " +
        'stage an unverifiable artifact.'
    )
}
