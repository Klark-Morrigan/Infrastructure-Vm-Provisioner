<#
.SYNOPSIS
    Acquire, verify, and stage the toolchain artifacts the Ansible toolchain
    flow (playbooks/provision-toolchains.yml) installs, then emit the concrete
    pinned versions those roles must be given.

.DESCRIPTION
    This is the consumer half of plan step 5.5's acquire/verify/stage gate.
    The substrate roles (Common-Ansible jdk / dotnet_sdk / dotnet_tools) pull
    their tarballs / packages from the host file server by archive name and
    deliberately do NOT verify a checksum at install (they trust the file
    server). Integrity therefore lives HERE, in the deploying consumer that
    owns the estate's egress: for each desired toolchain this script

      1. resolves the operator's loose pin against upstream into a concrete
         { resolved version, archive name, checksum, download URL } - reusing
         the reconciler's own pure resolvers so resolution stays one source
         of truth (Resolve-AdoptiumRelease / Resolve-DotnetSdkRelease and, for
         NuGet tools, the registration+catalog hash + ConvertFrom-NugetHash
         Base64 from Invoke-DotnetToolAcquisition);
      2. downloads the artifact from upstream and verifies its checksum,
         failing the whole staging run (nothing reaches any VM) on a mismatch;
      3. stages the verified artifact into the served directory under the EXACT
         archive name the role re-derives and pulls by;
      4. writes a per-artifact lockfile pinning { resolvedVersion, checksum,
         sourceUrl } - the equivalent of the reconciler's per-cache lockfile -
         so a re-run reuses the staged bytes instead of re-fetching; and
      5. writes a resolved-config document carrying the CONCRETE pins.

    The concrete pins in (5) are the point of the pin: the roles re-resolve on
    the target, so handing them the exact resolved version (e.g. "21.0.5+11"
    rather than "21") is what stops the target picking a newer upstream build
    than the one this step verified and staged. The wrapper forwards that
    document to ansible-playbook as an --extra-vars override.

    Structured as dot-sourceable functions with a run-guarded entry point so
    the resolve / download / verify boundary is unit-testable (Pester mocks the
    resolvers and Invoke-WebRequest / Get-FileHash) without a live network.

.NOTES
    Runs on the Windows host (SecretManagement + upstream egress live there),
    invoked by ops/_stage-toolchain-artifacts.sh before the bridge starts the
    file server. Reads Common.PowerShell for the retry helper the reused
    resolvers call; that import happens in the run-guarded entry block so a
    dot-source (test) load pulls in no modules.
#>

[CmdletBinding()]
param(
    # Loose desired-state source A: a JSON file. Primary input for tests and
    # the interim operator-supplied spec. Shape is a per-host map keyed by
    # vmName (every host and every key optional):
    #   { "ubuntu-01": { "jdk_versions": ["21"],
    #                    "dotnet_sdk_versions": [{"channel":"10.0","version":"10.0"}],
    #                    "dotnet_tools_tools": [{"id":"...","version":"5.4.4"}] } }
    [Parameter()]
    [string] $ToolchainsConfigPath,

    # Loose desired-state source B: read the per-VM VmProvisionerConfig-<Secret
    # Suffix> secret from the local VmProvisioner vault (the same secret the
    # bridge reads for its inventory, so desired-state and inventory share one
    # SSOT), and aggregate every VM's javaDevKit / dotnetSdk / dotnetTools into
    # the flat estate-wide superset the resolve/stage half below consumes.
    [Parameter()]
    [string] $SecretSuffix,

    # The directory the bridge's host file server will serve. Every verified
    # artifact is staged here under its role-pull archive name. Defaults under
    # LOCALAPPDATA so re-runs share a cache slot.
    [Parameter()]
    [string] $StagingDir,

    # Where the concrete pinned-versions document is written. Defaults inside
    # the staging dir. The wrapper forwards it to ansible-playbook as an
    # --extra-vars override.
    [Parameter()]
    [string] $ResolvedConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Reuse the reconciler's pure resolvers and the NuGet hash converter rather
# than re-deriving upstream-resolution logic in a second place. The relative
# reach into up/jdk and up/dotnet is a deliberate in-repo single-source-of-
# truth dependency (Ansible slice -> reconciler resolvers), documented so a
# reader knows the coupling is intentional. Invoke-DotnetToolAcquisition.ps1
# is dot-sourced only for ConvertFrom-NugetHashBase64; its Invoke-* function
# is not called here.
. "$PSScriptRoot\..\..\PowerShell\up\jdk\Resolve-AdoptiumRelease.ps1"
. "$PSScriptRoot\..\..\PowerShell\up\dotnet\Resolve-DotnetSdkRelease.ps1"
. "$PSScriptRoot\..\..\PowerShell\up\dotnet\Invoke-DotnetToolAcquisition.ps1"

# Desired-state now lives in the per-VM VmProvisionerConfig (the same secret the
# bridge reads for its inventory), so the vault source reuses that vault's
# single "vault -> validated VMs" entry point and projects each VM's toolchain
# fields into a per-host map keyed by vmName. Both are dot-sourced (functions
# only, no load-time side effects) for the same reason as the resolvers above.
. "$PSScriptRoot\..\..\PowerShell\common\config\Read-VmProvisionerConfig.ps1"
. "$PSScriptRoot\ConvertTo-PerVmToolchainConfig.ps1"

# ---------------------------------------------------------------------------
# Get-ToolchainArrayField
#   StrictMode-safe read of an optional array field off the parsed config.
#   A missing or null field reads as an empty array so an absent toolchain
#   section simply stages nothing (and later uninstalls it on the target).
# ---------------------------------------------------------------------------
function Get-ToolchainArrayField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string] $Name
    )

    # ,@(...) preserves array shape across the return so a single-element
    # section does not unwrap to a scalar (and the empty case does not unroll
    # to $null) - the shape trap the no-bare-return-empty-array lint guards.
    $prop = $Config.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value) {
        return , @()
    }
    return , @($prop.Value)
}

# ---------------------------------------------------------------------------
# Read-ToolchainDesiredState
#   Resolve the loose desired-state as a per-host map { vmName: { jdk_versions,
#   dotnet_sdk_versions, dotnet_tools_tools } } from whichever source the
#   caller named: a JSON file already in that shape (-ToolchainsConfigPath), or
#   the per-VM VmProvisionerConfig vault projected to it (-SecretSuffix).
#   Exactly one is required.
# ---------------------------------------------------------------------------
function Read-ToolchainDesiredState {
    [CmdletBinding()]
    param(
        [Parameter()] [string] $ConfigPath,
        [Parameter()] [string] $Suffix
    )

    $havePath   = -not [string]::IsNullOrWhiteSpace($ConfigPath)
    $haveSuffix = -not [string]::IsNullOrWhiteSpace($Suffix)
    if ($havePath -eq $haveSuffix) {
        throw (
            "Stage-ToolchainArtifacts: supply exactly one of " +
            "-ToolchainsConfigPath or -SecretSuffix."
        )
    }

    if ($havePath) {
        if (-not (Test-Path -LiteralPath $ConfigPath)) {
            throw "Stage-ToolchainArtifacts: config file '$ConfigPath' not found."
        }
        return (Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json)
    }

    # Vault path. Read the per-VM VmProvisionerConfig through its own single
    # "vault -> validated VMs" entry point (Read-VmProvisionerConfig), so the
    # config schema is validated in exactly one place, then project each VM's
    # toolchain fields into a per-host map keyed by vmName. Each host installs
    # only its own toolchains (the playbook looks its entry up by
    # inventory_hostname).
    $vmDefs = Read-VmProvisionerConfig -SecretSuffix $Suffix
    return (ConvertTo-PerVmToolchainConfig -VmConfigs $vmDefs)
}

# ---------------------------------------------------------------------------
# Save-VerifiedArtifact
#   Download Url to Destination and verify its checksum, or reuse an already
#   staged+pinned copy. The verification is the integrity gate the roles skip:
#   a mismatch removes the partial file and throws, so nothing corrupt is ever
#   left in the served directory. A sidecar <archive>.lock.json pins the
#   resolution so a re-run with a matching hash skips the download entirely.
# ---------------------------------------------------------------------------
function Save-VerifiedArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] [string] $Destination,
        [Parameter(Mandatory)] [string] $ExpectedHashHex,
        [Parameter(Mandatory)] [ValidateSet('SHA256', 'SHA512')] [string] $Algorithm,
        [Parameter(Mandatory)] [string] $ResolvedVersion
    )

    $lockPath = "$Destination.lock.json"

    # Cache hit: a staged artifact plus a lockfile whose pinned hash still
    # matches the bytes on disk. Reuses the verified copy instead of paying
    # the download again, matching the reconciler's lockfile-authoritative
    # reuse.
    if ((Test-Path -LiteralPath $lockPath) -and (Test-Path -LiteralPath $Destination)) {
        $onDisk = (Get-FileHash -LiteralPath $Destination -Algorithm $Algorithm).Hash
        if ($onDisk -ieq $ExpectedHashHex) {
            [Console]::Error.WriteLine("  Cache hit: $Destination")
            return
        }
    }

    [Console]::Error.WriteLine("  Fetching $Url")
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing

    $actual = (Get-FileHash -LiteralPath $Destination -Algorithm $Algorithm).Hash
    if ($actual -ine $ExpectedHashHex) {
        # Remove the corrupt/partial file so the served directory never
        # exposes an unverified artifact and a re-run starts clean.
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw (
            "Stage-ToolchainArtifacts: checksum mismatch for '$Destination'. " +
            "Upstream advertised '$ExpectedHashHex' but the download from " +
            "'$Url' hashed to '$actual'. Nothing staged."
        )
    }

    # Pin only after a clean verify, so an aborted run leaves no stale lock.
    [pscustomobject]@{
        resolvedVersion = $ResolvedVersion
        checksum        = $ExpectedHashHex
        algorithm       = $Algorithm
        sourceUrl       = $Url
    } | ConvertTo-Json | Set-Content -LiteralPath $lockPath -Encoding UTF8
    [Console]::Error.WriteLine("  Staged + pinned: $Destination")
}

# ---------------------------------------------------------------------------
# Resolve-NugetPackageHash
#   Follow NuGet v3 registration -> catalogEntry to the authoritative
#   SHA-512 packageHash for a tool, returned as uppercase hex alongside the
#   .nupkg download URL. Mirrors the reconciler's tool-acquisition metadata
#   walk; ConvertFrom-NugetHashBase64 is the reused converter.
# ---------------------------------------------------------------------------
function Resolve-NugetPackageHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [string] $Version
    )

    $idLower   = $Id.ToLowerInvariant()
    $sourceUrl = "https://www.nuget.org/api/v2/package/$Id/$Version"

    $registrationUrl =
        "https://api.nuget.org/v3/registration5-semver1/$idLower/$Version.json"
    $registration = Invoke-RestMethod -Uri $registrationUrl -UseBasicParsing

    $catalogProp = $registration.PSObject.Properties['catalogEntry']
    $catalogUrl  = if ($catalogProp) { [string]$catalogProp.Value } else { $null }
    if ([string]::IsNullOrEmpty($catalogUrl)) {
        throw (
            "Stage-ToolchainArtifacts: registration for '$Id@$Version' at " +
            "'$registrationUrl' has no catalogEntry URL; cannot pin a hash."
        )
    }

    $catalog  = Invoke-RestMethod -Uri $catalogUrl -UseBasicParsing
    $hashProp = $catalog.PSObject.Properties['packageHash']
    $algoProp = $catalog.PSObject.Properties['packageHashAlgorithm']
    $hash64   = if ($hashProp) { [string]$hashProp.Value } else { $null }
    $algo     = if ($algoProp) { [string]$algoProp.Value } else { $null }
    if ([string]::IsNullOrEmpty($hash64) -or [string]::IsNullOrEmpty($algo)) {
        throw (
            "Stage-ToolchainArtifacts: catalog entry for '$Id@$Version' at " +
            "'$catalogUrl' is missing packageHash / packageHashAlgorithm."
        )
    }
    if ($algo -ine 'SHA512') {
        throw (
            "Stage-ToolchainArtifacts: '$Id@$Version' advertises hash " +
            "algorithm '$algo'; only SHA512 is supported."
        )
    }

    return [pscustomobject]@{
        HashHex   = (ConvertFrom-NugetHashBase64 -Base64 $hash64)
        SourceUrl = $sourceUrl
    }
}

# ---------------------------------------------------------------------------
# Invoke-ToolchainStaging
#   The orchestrator: read desired-state, resolve+verify+stage each toolchain,
#   write the resolved-config pin document, and emit the three KEY=value
#   contract lines the bash wrapper parses (STAGING_DIR / STAGING_VERSION /
#   RESOLVED_CONFIG). Progress narration goes to stderr so stdout carries only
#   the contract.
# ---------------------------------------------------------------------------
function Invoke-ToolchainStaging {
    [CmdletBinding()]
    param(
        [Parameter()] [string] $ConfigPath,
        [Parameter()] [string] $Suffix,
        [Parameter()] [string] $StagingDirectory,
        [Parameter()] [string] $ResolvedConfigOut
    )

    if ([string]::IsNullOrWhiteSpace($StagingDirectory)) {
        $StagingDirectory =
            Join-Path $env:LOCALAPPDATA 'CommonAutomation\toolchain-staging'
    }
    if ([string]::IsNullOrWhiteSpace($ResolvedConfigOut)) {
        $ResolvedConfigOut = Join-Path $StagingDirectory 'resolved-toolchains.json'
    }
    $null = New-Item -ItemType Directory -Path $StagingDirectory -Force

    $desiredByHost = Read-ToolchainDesiredState -ConfigPath $ConfigPath -Suffix $Suffix

    # Resolve each host's loose pins to concrete builds, staging + verifying
    # each UNIQUE artifact once. The caches memoize across hosts so a JDK / SDK
    # / tool shared by several VMs is resolved, downloaded, and checksum-checked
    # a single time (Save-VerifiedArtifact is itself idempotent via its
    # lockfile, but the caches also skip the redundant upstream metadata fetch).
    $jdkCache  = @{}   # loose pin         -> concrete jdk version
    $sdkCache  = @{}   # "channel|version" -> { channel, concrete version }
    $toolCache = @{}   # "id|version"      -> { id, version }

    # Per-host concrete map. The playbook looks each host up by
    # inventory_hostname; a host absent here installs nothing.
    $resolvedByHost = [ordered]@{}

    # Iterate the property collection directly (not .Properties.Name): under
    # StrictMode, member-enumerating .Name off an EMPTY object - a fleet with no
    # toolchains - throws "property 'Name' cannot be found".
    foreach ($hostProp in $desiredByHost.PSObject.Properties) {
        $vmName = $hostProp.Name
        $cfg    = $hostProp.Value

        $hostJdk   = @()
        $hostSdk   = @()
        $hostTools = @()

        foreach ($pin in (Get-ToolchainArrayField -Config $cfg -Name 'jdk_versions')) {
            $key = [string]$pin
            if (-not $jdkCache.ContainsKey($key)) {
                [Console]::Error.WriteLine("Resolving JDK '$key' ...")
                $r = Resolve-AdoptiumRelease -Vendor 'temurin' -Version $key
                Save-VerifiedArtifact `
                    -Url             $r.DownloadUrl `
                    -Destination     (Join-Path $StagingDirectory $r.ArchiveName) `
                    -ExpectedHashHex $r.Sha256 `
                    -Algorithm       'SHA256' `
                    -ResolvedVersion $r.ResolvedVersion
                # The role accepts a full "21.0.5+11" pin and re-resolves it to
                # this exact build, so the concrete resolved version IS the pin.
                $jdkCache[$key] = $r.ResolvedVersion
            }
            $hostJdk += $jdkCache[$key]
        }

        foreach ($entry in (Get-ToolchainArrayField -Config $cfg -Name 'dotnet_sdk_versions')) {
            $channel = [string]$entry.channel
            $version = [string]$entry.version
            $key = "$channel|$version"
            if (-not $sdkCache.ContainsKey($key)) {
                [Console]::Error.WriteLine("Resolving .NET SDK '$channel' / '$version' ...")
                $r = Resolve-DotnetSdkRelease -Channel $channel -RequestedVersion $version
                # The .NET file name is the download URL's leaf, exactly the
                # archive the dotnet_sdk role re-derives and pulls by.
                $archive = Split-Path -Leaf $r.DownloadUrl
                Save-VerifiedArtifact `
                    -Url             $r.DownloadUrl `
                    -Destination     (Join-Path $StagingDirectory $archive) `
                    -ExpectedHashHex $r.Sha512 `
                    -Algorithm       'SHA512' `
                    -ResolvedVersion $r.ResolvedVersion
                # Pin the channel's resolved SDK to its exact version so the
                # role's re-resolve is deterministic.
                $sdkCache[$key] = [pscustomobject]@{
                    channel = $channel
                    version = $r.ResolvedVersion
                }
            }
            $hostSdk += $sdkCache[$key]
        }

        foreach ($tool in (Get-ToolchainArrayField -Config $cfg -Name 'dotnet_tools_tools')) {
            $id      = [string]$tool.id
            $version = [string]$tool.version
            $key = "$id|$version"
            if (-not $toolCache.ContainsKey($key)) {
                [Console]::Error.WriteLine("Resolving .NET tool '$id@$version' ...")
                $meta    = Resolve-NugetPackageHash -Id $id -Version $version
                $archive = "dotnet-tool-$id-$version.nupkg"
                Save-VerifiedArtifact `
                    -Url             $meta.SourceUrl `
                    -Destination     (Join-Path $StagingDirectory $archive) `
                    -ExpectedHashHex $meta.HashHex `
                    -Algorithm       'SHA512' `
                    -ResolvedVersion $version
                # Tool pins are already exact (id + exact NuGet version).
                $toolCache[$key] = [pscustomobject]@{ id = $id; version = $version }
            }
            $hostTools += $toolCache[$key]
        }

        # @() casts keep single-element results as JSON arrays.
        $resolvedByHost[$vmName] = [pscustomobject]@{
            jdk_versions        = @($hostJdk)
            dotnet_sdk_versions = @($hostSdk)
            dotnet_tools_tools  = @($hostTools)
        }
    }

    # The pinned document handed to the roles, keyed by host under a single
    # top-level wrapper key so it rides the play-wide --extra-vars channel
    # without colliding with any role var; the consumer playbook selects each
    # host's entry by inventory_hostname.
    $resolved = [pscustomobject]@{
        toolchains_resolved_by_host = [pscustomobject]$resolvedByHost
    }
    $resolvedJson = $resolved | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $ResolvedConfigOut -Value $resolvedJson -Encoding UTF8

    # A stable descriptor of exactly what was staged. The file server contract
    # requires a non-empty version string; the toolchain roles pull by archive
    # name and never read it, so a digest of the pinned set is the honest value
    # (it changes only when the staged resolution changes).
    $digestBytes = [System.Text.Encoding]::UTF8.GetBytes($resolvedJson)
    $sha         = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stagingVersion =
            ([System.BitConverter]::ToString($sha.ComputeHash($digestBytes)) `
                -replace '-', '').Substring(0, 12).ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }

    # Contract lines on stdout for ops/_stage-toolchain-artifacts.sh to parse.
    Write-Output "STAGING_DIR=$StagingDirectory"
    Write-Output "STAGING_VERSION=$stagingVersion"
    Write-Output "RESOLVED_CONFIG=$ResolvedConfigOut"
}

# Run-guarded entry: only when executed as a script (pwsh -File ...), not when
# dot-sourced by the Pester suite. Common.PowerShell is imported here (not at
# load time) so a dot-source pulls in no modules; the reused resolvers call
# its retry helper on the live metadata path.
if ($MyInvocation.InvocationName -ne '.') {
    Import-Module Common.PowerShell -ErrorAction Stop
    Invoke-ToolchainStaging `
        -ConfigPath        $ToolchainsConfigPath `
        -Suffix            $SecretSuffix `
        -StagingDirectory  $StagingDir `
        -ResolvedConfigOut $ResolvedConfigPath
}
