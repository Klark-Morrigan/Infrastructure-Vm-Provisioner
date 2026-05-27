<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    Get-DotnetSdkProvider, which composes the four provider operations
    into a single IToolchainProvider object.
#>

# ---------------------------------------------------------------------------
# Install-DotnetSdkVersion
#   Composition step driven by the reconciler: extract the prefetched
#   tarball, write /etc/profile.d/dotnet.sh, create the /usr/local/bin
#   symlink for the dotnet driver, and finally write the manifest that
#   records ownership of all four artefact kinds.
#
#   Side-effect ordering is load-bearing for crash recovery: the manifest
#   is written LAST. If the install crashes after the extract but before
#   the manifest write, the next reconciler run sees no manifest, treats
#   the install dir as orphaned, and re-runs Install-DotnetSdkVersion
#   which Expand-VmTarball's atomic dir-swap re-extracts cleanly. A
#   manifest written first would instead claim ownership of paths that
#   may not exist yet, and the uninstall path would happily try to drain
#   processes from a directory the install never finished creating.
#
#   TarballPath and resolved Version travel on the Spec itself (unlike
#   JDK, where TarballPath has to be closure-captured from $Vm). The
#   dotnet desired-versions step stamps both onto the Spec from
#   $Vm._dotnetSdk* so this function takes no extra parameters beyond
#   the contract triple ($SshClient, $Server, $Spec).
#
#   Differences from JdkProvider.Install-Version:
#     - StripComponents = 0: Microsoft's SDK tarball lays its files at
#       the archive root (no wrapper directory), unlike Adoptium's JDK
#       tarballs which wrap everything under jdk-<version>/.
#     - Single /usr/local/bin symlink for `dotnet`: every other SDK tool
#       (`dotnet build`, `dotnet test`, ...) is dispatched by the driver,
#       so there is no per-binary enumeration to do.
#     - profile.d exports DOTNET_ROOT (the SDK uses it to find shared
#       frameworks when launched outside its install dir) and opts the
#       VM out of CLI telemetry by default. Unattended CI runners have
#       no operator to consent to telemetry, and the opt-out is per-shell
#       so it has to be in the profile.d script rather than a one-shot
#       env edit during provisioning.
# ---------------------------------------------------------------------------

function Install-DotnetSdkVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [object] $Server,

        [Parameter(Mandatory)]
        [object] $Spec,

        # Optional - present when the SDK install is followed by the
        # nested dotnetTools provider in the same provision run. The
        # SDK provider is the only place the parent depends on the
        # child (dependency direction: parent-knows-children), so the
        # caller (Get-DotnetSdkProvider) is responsible for resolving
        # the per-Vm child entry list via Get-VmDotnetToolChildren and
        # forwarding it here. Default empty so existing call sites
        # (and SDK-only fixtures) stay unaffected.
        [AllowEmptyCollection()]
        [object[]] $ChildEntries = @()
    )

    $resolvedVersion = $Spec.Version
    $tarballPath     = $Spec.TarballPath
    $installDir      = "/opt/dotnet-$resolvedVersion"

    Write-Host "  [dotnet] SDK $resolvedVersion -> $installDir"

    # Step 1 - extract. StripComponents=0 because the .NET SDK tarball
    # lays its files at the archive root (no wrapper dir to discard).
    Expand-VmTarball `
        -SshClient       $SshClient `
        -Server          $Server `
        -TarballPath     $tarballPath `
        -Destination     $installDir `
        -StripComponents 0

    # Step 2 - login-shell PATH + DOTNET_ROOT + telemetry opt-out via
    # /etc/profile.d. Single-quoted right-hand sides so the values stay
    # literal in the written .sh and the user's shell expands them at
    # login, not host-side at construction time.
    #
    # The tools dir (/usr/local/share/dotnet/tools) is prepended too so a
    # login shell sees globally-installed `dotnet tool` commands on PATH
    # without each tool needing its own profile.d entry. The dir is
    # owned by the nested dotnetTools provider; writing the PATH here
    # (rather than in a sibling tools.sh) keeps one source of truth for
    # the dotnet PATH and avoids drift between SDK and tools install
    # state. The dir exists even when no tools are installed - the
    # first `dotnet tool install --tool-path` creates it - so prepending
    # it unconditionally is safe.
    $dotnetSh = @(
        "export DOTNET_ROOT=$installDir"
        'export DOTNET_TOOLS_ROOT=/usr/local/share/dotnet/tools'
        'export PATH="$DOTNET_ROOT:$DOTNET_TOOLS_ROOT:$PATH"'
        'export DOTNET_CLI_TELEMETRY_OPTOUT=1'
        ''
    ) -join "`n"

    Set-VmProfileDScript `
        -SshClient $SshClient `
        -Name      'dotnet' `
        -Content   $dotnetSh

    # Step 3 - non-login-shell PATH via /usr/local/bin (sshd command
    # exec, systemd services, cron jobs - none of these read
    # /etc/profile.d/). One link is enough: every SDK tool runs through
    # the `dotnet` driver via `dotnet <verb>`.
    $linkPath   = '/usr/local/bin/dotnet'
    $linkTarget = "$installDir/dotnet"

    New-VmSymlink `
        -SshClient $SshClient `
        -Path      $linkPath `
        -Target    $linkTarget

    # Step 4 - /etc/dotnet/install_location. The dotnet apphost (the
    # tiny native binary every `dotnet tool install` shim is built
    # around) probes for the .NET runtime in this fixed order:
    # DOTNET_ROOT env var, then a Microsoft-baked default that points
    # at /usr/share/dotnet, then /etc/dotnet/install_location. Because
    # we install to /opt/dotnet-<version> (not the baked default) AND
    # DOTNET_ROOT is only set in login shells (profile.d), a global
    # tool invoked from a non-login shell (sshd command exec, systemd
    # units, cron) has no way to find the runtime - which surfaces as
    # "You must install .NET to run this application" on first tool
    # invocation. Writing the install path here is Microsoft's
    # documented escape hatch and works regardless of shell type.
    # Path is fixed (one global SDK install per VM); uninstall removes
    # the file in lockstep.
    $installLocationScript = @"
set -euo pipefail
sudo mkdir -p /etc/dotnet
printf '%s\n' '$installDir' | sudo tee /etc/dotnet/install_location > /dev/null
sudo chmod 0644 /etc/dotnet/install_location
"@ -replace "`r`n", "`n"

    $installLocationResult = Invoke-SshClientCommand `
                                -SshClient $SshClient `
                                -Command   $installLocationScript
    if ($installLocationResult.ExitStatus -ne 0) {
        throw (
            "Install-DotnetSdkVersion: writing /etc/dotnet/install_location " +
            "failed (exit $($installLocationResult.ExitStatus)). " +
            "stdout: $($installLocationResult.Output)  " +
            "stderr: $($installLocationResult.Error)"
        )
    }

    # Step 5 - manifest, written LAST. See the function header for why
    # the ordering matters. ownedPaths[0] is the install dir; the
    # Get-DotnetSdkInstalledVersions reader assumes this invariant when
    # projecting the manifest into an Installed record.
    $manifest = [PSCustomObject]@{
        schemaVersion       = 1
        provider            = 'dotnetSdk'
        version             = $resolvedVersion
        ownedPaths          = @($installDir)
        ownedSymlinks       = @(
            [PSCustomObject]@{
                path   = $linkPath
                target = $linkTarget
            }
        )
        ownedProfileScripts = @('dotnet')
        # Children walker (reconciler Phase A) reads this array at
        # parent-uninstall time to dispatch each registered nested
        # provider's Uninstall-Version BEFORE the SDK is removed. Each
        # entry is { provider, manifestPath } - see Provider-Contract.ps1
        # and Invoke-ToolchainChildrenUninstall. Populated from the
        # operator's `dotnetTools` config at install time (see header
        # for the dependency direction rationale); explicit empty array
        # when the operator declared no tools or omitted the field.
        children            = @($ChildEntries)
    }

    Write-VmManifest -SshClient $SshClient -Manifest $manifest

    Write-Host "  [dotnet] [OK] installed under $installDir." -ForegroundColor Green
}
