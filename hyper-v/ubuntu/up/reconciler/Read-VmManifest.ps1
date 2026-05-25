<#
.SYNOPSIS
    Reads one sidecar manifest from the VM by absolute path.

.DESCRIPTION
    Runs `sudo cat -- '<Path>'` over SSH and parses the result as JSON.
    Returns a [PSCustomObject] mirroring the manifest schema documented
    in docs/dev/implementation/42 - dotnet sdk/problem.md.

    Throws when:
      - the SSH command exits non-zero (file missing or unreadable),
      - the body is not valid JSON,
      - the body is missing the `schemaVersion` field,
      - `schemaVersion` is not 1 (the only shape this codebase
        understands; a future migration would land alongside a bump
        and explicit translation).

    The function does NOT attach the source path to the returned
    object. The companion helper Get-VmManifestsByProvider attaches a
    `_manifestPath` member so callers (Get-InstalledVersions in step 7)
    can pair each parsed manifest with its on-disk location.

.PARAMETER SshClient
    A live SSH client. Caller owns the lifecycle.

.PARAMETER Path
    Absolute POSIX path of the manifest file on the VM.
#>
function Read-VmManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $Path
    )

    Assert-VmManifestPath -Path $Path -CmdletName 'Read-VmManifest'

    $command = "sudo cat -- '$Path'"
    $result  = Invoke-SshClientCommand -SshClient $SshClient -Command $command

    if ($result.ExitStatus -ne 0) {
        throw (
            "Read-VmManifest: failed to read '$Path' " +
            "(exit $($result.ExitStatus)). " +
            "stdout: $($result.Output)  stderr: $($result.Error)"
        )
    }

    try {
        # -ErrorAction Stop turns ConvertFrom-Json's non-terminating
        # parse error into a terminating one that the catch below can
        # rewrap with the manifest path for an operator-friendly
        # message.
        $manifest = $result.Output | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Read-VmManifest: '$Path' is not valid JSON: $($_.Exception.Message)"
    }

    if ($null -eq $manifest) {
        throw "Read-VmManifest: '$Path' parsed to null (empty file?)."
    }

    # PSCustomObject path: .PSObject.Properties; we don't need the
    # hashtable branch because ConvertFrom-Json always yields a
    # PSCustomObject for JSON objects.
    if ($null -eq $manifest.PSObject.Properties['schemaVersion']) {
        throw "Read-VmManifest: '$Path' is missing required 'schemaVersion' field."
    }

    if ($manifest.schemaVersion -ne 1) {
        throw (
            "Read-VmManifest: '$Path' has unsupported schemaVersion " +
            "'$($manifest.schemaVersion)'; this code understands only 1."
        )
    }

    return $manifest
}

# Path validation shared with Remove-VmManifest. Embedded into the
# emitted bash inside a single-quoted assignment, so a literal single
# quote, NUL, or `..` segment is rejected up front.
function Assert-VmManifestPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $CmdletName
    )

    if ([string]::IsNullOrEmpty($Path)) {
        throw "${CmdletName}: -Path must be a non-empty string."
    }
    if (-not $Path.StartsWith('/')) {
        throw "${CmdletName}: -Path '$Path' must be an absolute POSIX path."
    }
    if ($Path.Contains([char]0)) {
        throw "${CmdletName}: -Path contains a NUL byte."
    }
    if ($Path.Contains("'")) {
        throw "${CmdletName}: -Path '$Path' contains a single quote."
    }
    if ($Path.Contains("`n") -or $Path.Contains("`r")) {
        throw "${CmdletName}: -Path '$Path' contains a newline."
    }
    if ($Path.Split('/') -contains '..') {
        throw "${CmdletName}: -Path '$Path' contains a '..' segment."
    }
}
