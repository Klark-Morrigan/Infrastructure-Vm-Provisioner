<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    Get-DotnetToolsProvider (step 6), which composes the four provider
    operations into a single IToolchainProvider object.
#>

# ---------------------------------------------------------------------------
# Install-DotnetToolVersion
#   Composition step driven by the reconciler: stage the cached .nupkg into
#   a per-tool staging dir on the VM, run `dotnet tool install` against that
#   dir as a NuGet source, enumerate the installed tool's command names,
#   create per-command /usr/local/bin/ symlinks, and finally write the
#   manifest that records ownership. The staging dir is wiped after the
#   manifest is written.
#
#   Side-effect ordering is load-bearing for crash recovery: the manifest
#   is written LAST (after install + symlinks). A crash before the manifest
#   leaves no record of the install; the next reconciler run treats the
#   tools-dir contents as foreign (per Ownership boundary, problem.md) and
#   the operator can recover by re-provisioning - dotnet tool install is
#   idempotent on the same version.
#
#   --tool-path is /usr/local/share/dotnet/tools so the install is system-
#   wide and survives user reprovisions. The .store/ subdirectory under
#   that path is what we record as the owned install dir; the top-level
#   `{cmd}` shim under tools/ is referenced by the /usr/local/bin/ symlink
#   so non-login shells (sshd command exec, systemd units, cron) can find
#   the tool without sourcing /etc/profile.d/.
#
#   --configfile points the resolver at a minimal NuGet.Config written
#   into the staging dir that declares ONLY the staging dir as a source
#   (with <clear /> to drop any ambient nuget.org entry). Per the
#   `dotnet tool install` docs, --configfile means "only the settings
#   from this file will be used", so the resolver never contacts
#   api.nuget.org for its service index. This honours the Phase B /
#   Option B design (host prefetches + SHA-512-verifies, VM consumes
#   pre-verified bytes only) - without --configfile, --add-source merely
#   APPENDS to the ambient sources and a transient socket failure
#   against api.nuget.org:443 aborts the install before the local
#   source is ever consulted; --ignore-failed-sources is documented to
#   handle that case but does not in SDK 8.0.x (service-index probes
#   are not treated as "failed sources" the way package fetches are).
# ---------------------------------------------------------------------------

# Tools live under a fixed system-wide path so every shell that gets PATH
# from /etc/profile.d/dotnet.sh (login) or via the /usr/local/bin/ symlinks
# (non-login) finds them. Hardcoded because the path is the public contract
# of the provider; changing it is a manifest-schema break.
$script:DotnetToolsRoot = '/usr/local/share/dotnet/tools'

function Install-DotnetToolVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [object] $Server,

        [Parameter(Mandatory)]
        [object] $Spec
    )

    $id              = [string]$Spec.Id
    $version         = [string]$Spec.RawVersion
    $nupkgPath       = [string]$Spec.NupkgPath
    $name            = "$id@$version"
    $stagingDir      = "/var/lib/infra-provisioner/staging/dotnet-tools/$name"
    $nugetConfigPath = "$stagingDir/NuGet.Config"
    $toolsRoot       = $script:DotnetToolsRoot
    $storeDir        = "$toolsRoot/.store/$id/$version"

    Write-Host "  [dotnetTools] $name -> $toolsRoot"

    # Step 1 - stage the host-cached .nupkg into a per-tool dir on the VM,
    # alongside a NuGet.Config that pins the staging dir as the sole
    # source. <clear /> drops any ambient nuget.org entry that machine /
    # user / dotnet-shipped config might contribute, so the resolver has
    # exactly one local source to consider when --configfile points here.
    # Use the same Add-VmFileServerFile + curl pattern Expand-VmTarball
    # uses internally; we cannot reuse Expand-VmTarball itself because it
    # pipes into `tar -xzf -` and the .nupkg is a zip, not a gzip tarball.
    #
    # The staged file is written under NuGet's V2 flat-layout filename -
    # '{idLower}.{version}.nupkg' - rather than the host-cache filename
    # ('dotnet-tool-{id}-{version}.nupkg'). The local-source enumerator
    # in SDK 8.0.x matches packages by parsing the filename against
    # `{id}.{version}.nupkg`; a file that does not match that pattern
    # is invisible to the resolver and surfaces as
    # "<id>::[<version>, ) is not found in NuGet feeds <stagingDir>".
    # The host cache filename is left alone (its convention is its own
    # cache key); the rename is local to the staging copy.
    $nupkgUrl       = Add-VmFileServerFile -Server $Server -LocalPath $nupkgPath
    $stagedNupkgLeaf = "$($id.ToLowerInvariant()).$version.nupkg"

    # Bash heredoc delimiter is quoted ('NUGETCONFIG') so the VM-side
    # shell does NOT expand $stagingDir or backticks while writing the
    # file. The PowerShell here-string above already substituted
    # $stagingDir into the file body host-side.
    $stagingScript = @"
set -euo pipefail
sudo mkdir -p '$stagingDir'
sudo chmod 0755 '$stagingDir'
curl -fsSL '$nupkgUrl' | sudo tee '$stagingDir/$stagedNupkgLeaf' >/dev/null
sudo tee '$nugetConfigPath' >/dev/null <<'NUGETCONFIG'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="local-staging" value="$stagingDir" />
  </packageSources>
</configuration>
NUGETCONFIG
"@
    # CRLF -> LF (Windows here-strings would otherwise tag a `\r` onto
    # every line and bash would parse it as part of the previous token).
    $stagingScript = $stagingScript -replace "`r`n", "`n"

    $stageResult = Invoke-SshClientCommand -SshClient $SshClient -Command $stagingScript
    if ($stageResult.ExitStatus -ne 0) {
        throw (
            "Install-DotnetToolVersion: staging '$name' to '$stagingDir' " +
            "failed (exit $($stageResult.ExitStatus)). " +
            "stdout: $($stageResult.Output)  stderr: $($stageResult.Error)"
        )
    }

    # Step 2 - dotnet tool install. The driver provides idempotency on the
    # same version (a second install of the same id@version is a no-op
    # error, so a re-provision recovers cleanly from a mid-install crash).
    # --configfile means "only the settings from this file will be used"
    # (per `dotnet tool install --help`), so the resolver consults the
    # staging dir alone and never touches the network.
    $installScript = @"
set -euo pipefail
sudo dotnet tool install '$id' \
    --tool-path '$toolsRoot' \
    --configfile '$nugetConfigPath' \
    --version '$version'
"@
    $installScript = $installScript -replace "`r`n", "`n"

    $installResult = Invoke-SshClientCommand -SshClient $SshClient -Command $installScript
    if ($installResult.ExitStatus -ne 0) {
        throw (
            "Install-DotnetToolVersion: 'dotnet tool install $name' failed " +
            "(exit $($installResult.ExitStatus)). " +
            "stdout: $($installResult.Output)  stderr: $($installResult.Error)"
        )
    }

    # Step 3 - enumerate the just-installed command name(s). `dotnet tool
    # list --tool-path` is the only first-party way to discover the
    # commands a tool exposes - they are recorded in the per-tool
    # DotnetToolSettings.xml inside .store/, but the driver's parser is
    # the supported surface. Parsing the table is fragile but the
    # alternative (peeking into .store/) couples us to internal layout.
    $listScript = @"
set -euo pipefail
sudo dotnet tool list --tool-path '$toolsRoot'
"@
    $listScript = $listScript -replace "`r`n", "`n"

    $listResult = Invoke-SshClientCommand -SshClient $SshClient -Command $listScript
    if ($listResult.ExitStatus -ne 0) {
        throw (
            "Install-DotnetToolVersion: 'dotnet tool list' failed after " +
            "installing '$name' (exit $($listResult.ExitStatus)). " +
            "stdout: $($listResult.Output)  stderr: $($listResult.Error)"
        )
    }

    $commands = Get-DotnetToolCommandsFromListOutput `
                    -Output $listResult.Output `
                    -Id     $id

    if ($commands.Count -eq 0) {
        throw (
            "Install-DotnetToolVersion: 'dotnet tool list' did not report any " +
            "commands for '$id' after install. Output: $($listResult.Output)"
        )
    }

    # Step 4 - per-command /usr/local/bin/ symlinks. The tool driver
    # places a shim binary at $toolsRoot/{cmd} for each command, so the
    # symlink target is that shim (NOT the executable inside .store/).
    # New-VmSymlink is idempotent: an existing symlink pointing at the
    # same target is left alone, an existing symlink to a different
    # target is replaced.
    $ownedSymlinks = foreach ($cmd in $commands) {
        $linkPath   = "/usr/local/bin/$cmd"
        $linkTarget = "$toolsRoot/$cmd"

        New-VmSymlink `
            -SshClient $SshClient `
            -Path      $linkPath `
            -Target    $linkTarget

        [PSCustomObject]@{
            path   = $linkPath
            target = $linkTarget
        }
    }

    # Step 5 - manifest, written LAST. ownedPaths[0] is the per-tool
    # .store/ dir (the only thing the uninstall path needs to remove
    # via `dotnet tool uninstall`). `version` is set to the composite
    # '{id}-{rawVersion}' so the filename Write-VmManifest emits is
    # unique per tool even when two tools share a NuGet version
    # ('dotnetTools-{id}-{rawVersion}.json'). Id and rawVersion are
    # carried as explicit fields so Get-InstalledVersions reads them
    # back without parsing the composite.
    $manifest = [PSCustomObject]@{
        schemaVersion       = 1
        provider            = 'dotnetTools'
        # Composite for unique filename; id/rawVersion are the real
        # identity fields.
        version             = "$id-$version"
        id                  = $id
        rawVersion          = $version
        ownedPaths          = @($storeDir)
        ownedSymlinks       = @($ownedSymlinks)
        commands            = @($commands)
        parentProvider      = 'dotnetSdk'
        installedAt         = (Get-Date).ToUniversalTime().ToString('o')
        children            = @()
    }

    Write-VmManifest -SshClient $SshClient -Manifest $manifest

    # Step 6 - wipe the staging dir. Cleanup is best-effort: a failure
    # here does not invalidate the install (the tool is in the store
    # and the manifest is written), so we log and move on rather than
    # throw and force a re-provision over a benign leftover.
    $cleanupScript = "sudo rm -rf -- '$stagingDir'"
    $cleanupResult = Invoke-SshClientCommand `
                        -SshClient $SshClient `
                        -Command   $cleanupScript
    if ($cleanupResult.ExitStatus -ne 0) {
        Write-Warning (
            "  [dotnetTools] staging cleanup for '$name' returned exit " +
            "$($cleanupResult.ExitStatus); leaving '$stagingDir' in place. " +
            "stderr: $($cleanupResult.Error)"
        )
    }

    Write-Host "  [dotnetTools] [OK] installed $name." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Get-DotnetToolCommandsFromListOutput
#   Parses the `dotnet tool list --tool-path ...` table output and returns
#   the command names (third column) for the row whose first column equals
#   the supplied Id (case-insensitive). Returns @() on no match - the
#   caller decides whether that is fatal.
#
#   Sample output:
#     Package Id                              Version      Commands
#     -----------------------------------------------------------------
#     dotnet-reportgenerator-globaltool       5.4.4        reportgenerator
#
#   The format is whitespace-separated with header + dash-rule; we skip
#   any line whose first column matches 'Package' (header) or starts with
#   a dash (rule). Multi-command tools list commands separated by a
#   comma or whitespace - we split on both to be tolerant.
# ---------------------------------------------------------------------------
function Get-DotnetToolCommandsFromListOutput {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Output,
        [Parameter(Mandatory)] [string] $Id
    )

    $lines = $Output -split "`r?`n"
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrEmpty($trimmed)) { continue }
        # Skip header and dash-rule.
        if ($trimmed.StartsWith('-')) { continue }

        # Whitespace-split into at most 3 tokens so the Commands column
        # (which may itself contain a comma-separated list) stays
        # intact as the final token.
        $tokens = $trimmed -split '\s+', 3
        if ($tokens.Count -lt 3) { continue }
        if ($tokens[0] -ieq 'Package') { continue }
        if ($tokens[0] -ieq $Id) {
            # Commands within a single tool may be comma- or
            # whitespace-separated depending on the driver version.
            $cmds = $tokens[2] -split '[,\s]+' |
                    ForEach-Object { $_.Trim() } |
                    Where-Object { -not [string]::IsNullOrEmpty($_) }
            return ,@($cmds)
        }
    }
    return ,@()
}
