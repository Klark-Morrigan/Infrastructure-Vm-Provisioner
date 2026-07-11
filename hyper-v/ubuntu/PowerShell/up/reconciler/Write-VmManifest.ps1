<#
.SYNOPSIS
    Serialises a manifest host-side and writes it to the on-VM store
    atomically, owner root:root, mode 0644.

.DESCRIPTION
    Composes the on-VM target path as
    /var/lib/infra-provisioner/manifests/{provider}-{version}.json
    from the input manifest's `provider` and `version` fields, JSON-
    serialises the manifest host-side via
    `ConvertTo-Json -Depth 6`, and pushes the result over SSH inside a
    single-quoted heredoc so embedded $ / " / backslashes survive
    byte-for-byte.

    The on-VM write is atomic: `sudo mktemp` in the store directory
    (same filesystem as the destination, so the final `mv` is atomic
    at the directory-entry level), `sudo tee` the content, chown +
    chmod the temp file, then `mv` it over the target. This mirrors
    the Set-VmProfileDScript pattern from Infrastructure.HyperV; we
    inline rather than depend on that module's private fragment
    helper because the helper is not exported.

.PARAMETER SshClient
    A live SSH client. Caller owns the lifecycle.

.PARAMETER Manifest
    A [PSCustomObject] (or hashtable) carrying at minimum the
    `provider`, `version`, and `schemaVersion` fields documented in
    problem.md.
#>
function Write-VmManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Manifest
    )

    if ($null -eq $Manifest) {
        throw "Write-VmManifest: -Manifest must not be null."
    }

    # PSCustomObject and hashtable expose membership differently: the
    # former through PSObject.Properties, the latter through
    # ContainsKey (PSObject.Properties does not see hashtable keys -
    # a strict-mode foot-gun also called out in the user's memory
    # index). Dispatch once, then index uniformly.
    $isHashtable = $Manifest -is [hashtable]
    $hasProvider = if ($isHashtable) { $Manifest.ContainsKey('provider') } else {
        $null -ne $Manifest.PSObject.Properties['provider']
    }
    $hasVersion  = if ($isHashtable) { $Manifest.ContainsKey('version') } else {
        $null -ne $Manifest.PSObject.Properties['version']
    }

    $provider = if ($hasProvider) { $Manifest.provider } else { $null }
    $version  = if ($hasVersion)  { $Manifest.version  } else { $null }

    if ([string]::IsNullOrWhiteSpace($provider)) {
        throw "Write-VmManifest: manifest.provider must be a non-empty string."
    }
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "Write-VmManifest: manifest.version must be a non-empty string."
    }
    # Same character class as Get-VmManifestsByProvider so a manifest
    # written here is findable by the read path's glob.
    if ($provider -notmatch '^[A-Za-z0-9_-]+$') {
        throw "Write-VmManifest: manifest.provider '$provider' must match ^[A-Za-z0-9_-]+`$."
    }
    if ($version -notmatch '^[A-Za-z0-9._+-]+$') {
        throw "Write-VmManifest: manifest.version '$version' must match ^[A-Za-z0-9._+-]+`$."
    }

    # See Initialize-VmManifestStore.ps1 for why this path is duplicated.
    $storePath  = '/var/lib/infra-provisioner/manifests'
    $targetPath = "$storePath/$provider-$version.json"

    # Depth 6 covers the documented schema (children -> child manifest
    # -> ownedSymlinks -> hashtable members) with headroom; any deeper
    # nesting would mean the manifest is doing too much. The helper
    # asserts byte-equality against this exact call in its unit tests.
    $json = ConvertTo-Json -InputObject $Manifest -Depth 6

    # Heredoc delimiter is namespaced + uppercase so it cannot collide
    # with anything ConvertTo-Json emits (JSON keys would be quoted).
    # `sudo mktemp` in the store directory (root:root 0755) because
    # the SSH user has no write permission there - a user-owned mktemp
    # would EACCES.
    $script = @"
set -euo pipefail
DESIRED=`$(cat <<'__INFRA_VM_PROVISIONER_MANIFEST__'
$json
__INFRA_VM_PROVISIONER_MANIFEST__
)
TMP=`$(sudo mktemp '$storePath/.tmp.XXXXXX')
printf '%s\n' "`$DESIRED" | sudo tee "`$TMP" >/dev/null
sudo chown root:root "`$TMP"
sudo chmod 0644 "`$TMP"
sudo mv "`$TMP" '$targetPath'
"@

    # Windows PowerShell here-strings use CRLF; remote bash interprets
    # the trailing \r as part of the token. Normalise to LF, same as
    # Infrastructure.HyperV's install primitives.
    $script = $script -replace "`r`n", "`n"

    $result = Invoke-SshClientCommand -SshClient $SshClient -Command $script
    if ($result.ExitStatus -ne 0) {
        throw (
            "Write-VmManifest failed for '$targetPath' " +
            "(exit $($result.ExitStatus)). " +
            "stdout: $($result.Output)  stderr: $($result.Error)"
        )
    }
}
