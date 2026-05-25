<#
.SYNOPSIS
    Enumerates and parses all manifests in the on-VM store that belong
    to a given toolchain provider.

.DESCRIPTION
    Lists /var/lib/infra-provisioner/manifests/{Provider}-*.json on the
    VM and parses each via Read-VmManifest. Returns an array of
    [PSCustomObject]s, each with the manifest body plus a synthetic
    `_manifestPath` NoteProperty pointing back at the source file so
    callers (Get-InstalledVersions, step 7) can pass it into
    Uninstall-Version later.

    Returns @() when the store directory does not exist OR when no
    manifest matches the provider prefix. "Nothing installed" is a
    valid state for the orchestrator, so absence is not an error.

.PARAMETER SshClient
    A live SSH client. Caller owns the lifecycle.

.PARAMETER Provider
    The provider field embedded in the manifest file name (e.g.
    'javaDevKit', 'dotnetSdk'). Restricted to a tight character class
    because it is interpolated into a shell glob.
#>
function Get-VmManifestsByProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $Provider
    )

    # Same character class as the provider Name members in
    # Provider-Contract.ps1 (kept tight so this value can be embedded
    # into a single-quoted shell glob with no metacharacter risk).
    if ($Provider -notmatch '^[A-Za-z0-9_-]+$') {
        throw (
            "Get-VmManifestsByProvider: -Provider '$Provider' must match " +
            "^[A-Za-z0-9_-]+`$ (used as a filename prefix in a shell glob)."
        )
    }

    # See Initialize-VmManifestStore.ps1 for why this path is duplicated.
    $storePath = '/var/lib/infra-provisioner/manifests'
    $glob      = "$storePath/$Provider-*.json"

    # `ls -1` to force one path per line. The glob is intentionally
    # NOT single-quoted: we want bash to expand `*` against the
    # filesystem. Single-quoting would treat the literal asterisk as
    # part of the filename and `ls` would always report "no such file".
    # Safe to leave unquoted because (a) $storePath is a hardcoded
    # constant and (b) $Provider is validated above against a tight
    # character class - no shell metacharacters can slip in.
    #
    # `2>&1 || true` is NOT used here: we want to distinguish "no
    # matches" (treated as @()) from "real I/O error" (rethrown).
    # Invoke-SshClientCommand keeps stdout and stderr separate, so the
    # check is straightforward.
    $listResult = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command "ls -1 -- $glob"

    if ($listResult.ExitStatus -ne 0) {
        # The "no such file or directory" exit covers both
        # store-missing and glob-no-match (bash expands an unmatched
        # glob to the literal pattern, which `ls` then reports as not
        # found). Both mean "no manifests for this provider", which is
        # the valid empty state, not an error.
        $combined = "$($listResult.Output) $($listResult.Error)"
        if ($combined -match 'No such file or directory') {
            # Comma operator preserves the empty array across the
            # function boundary (PowerShell unrolls a bare @() to
            # $null, which breaks the array contract).
            return ,@()
        }
        throw (
            "Get-VmManifestsByProvider: ls failed for provider '$Provider' " +
            "(exit $($listResult.ExitStatus)). " +
            "stdout: $($listResult.Output)  stderr: $($listResult.Error)"
        )
    }

    # Pipeline returns a scalar on single match under strict mode; wrap
    # in @(...) so the foreach below sees an array uniformly.
    $files = @(
        $listResult.Output -split "`n" |
            ForEach-Object { $_.Trim() } |
            Where-Object   { $_ -ne '' }
    )

    if ($files.Count -eq 0) { return ,@() }

    $manifests = foreach ($file in $files) {
        $manifest = Read-VmManifest -SshClient $SshClient -Path $file
        # Attach the source path so the caller can correlate parsed
        # records back to their on-disk location (needed by uninstall).
        Add-Member `
            -InputObject $manifest `
            -MemberType  NoteProperty `
            -Name        '_manifestPath' `
            -Value       $file `
            -Force
        $manifest
    }

    # Comma operator preserves array shape when the foreach yields a
    # single element (otherwise PowerShell unrolls it back to a scalar).
    return ,@($manifests)
}
