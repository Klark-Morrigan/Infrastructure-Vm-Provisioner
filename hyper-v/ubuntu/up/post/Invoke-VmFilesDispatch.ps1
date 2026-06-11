<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1.
#>

# ---------------------------------------------------------------------------
# Invoke-VmFilesDispatch
#   Routes each entry in a VM's `files` array to either Copy-VmFiles
#   (single source/target) or Copy-VmFilesByPattern (bulk source pattern
#   + targetDir). The discriminator is presence of 'pattern' on the
#   entry - the schema in
#   common/config/ConvertFrom-VmConfigJson.ps1 guarantees the entry is
#   well-formed for whichever branch matches.
#
#   Per-entry dispatch (not "all singles then all bulks") keeps two
#   contracts simultaneously:
#     - Operator-visible logging and any side effects appear in the
#       same order the operator wrote them in the JSON config.
#     - Each bulk entry's resolver errors (zero matches, target
#       collisions, etc.) surface against the SPECIFIC files entry
#       that triggered them, so the operator knows which entry to
#       fix.
#
#   Provisioner policy: every user file lands as root:root, 0644.
#   User-owned files belong in Vm-Users (which runs after the users
#   exist).
#
#   Optional booleans (recurse, preserveRelativePath) default to
#   $false when absent so the JSON round-trip through the schema
#   stays a pure pass-through (default applied here, not in the
#   validator).
# ---------------------------------------------------------------------------

function Invoke-VmFilesDispatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [object] $Server,

        # Entries from the VM definition's `files` field. Each entry
        # is either a single { source, target } pair or a bulk
        # { pattern, targetDir, recurse?, preserveRelativePath? }
        # block. Accepting both shapes (no enforced type) keeps this
        # function aligned with the schema validator's
        # discriminator: presence of `pattern` == bulk.
        [object[]] $Entries
    )

    Write-Host "  [files] processing $(@($Entries).Count) entry(s) ..."

    foreach ($entry in @($Entries)) {
        if ($entry.PSObject.Properties['pattern']) {
            $pattern   = $entry.pattern
            $targetDir = $entry.targetDir

            $recurseProp = $entry.PSObject.Properties['recurse']
            $recurse = if ($null -ne $recurseProp) {
                [bool]$recurseProp.Value
            } else { $false }

            $preserveProp = $entry.PSObject.Properties['preserveRelativePath']
            $preserveRelativePath = if ($null -ne $preserveProp) {
                [bool]$preserveProp.Value
            } else { $false }

            Write-Host "  [files] bulk: $pattern -> $targetDir"
            Copy-VmFilesByPattern -SshClient $SshClient `
                                  -Server    $Server `
                                  -Pattern   $pattern `
                                  -TargetDir $targetDir `
                                  -Recurse:$recurse `
                                  -PreserveRelativePath:$preserveRelativePath
        } else {
            $singleEntries = @(
                [PSCustomObject]@{ Source = $entry.source; Target = $entry.target }
            )
            Write-Host "  [files] single: $($entry.source) -> $($entry.target)"
            Copy-VmFiles -SshClient $SshClient `
                         -Server    $Server `
                         -Entries   $singleEntries
        }
    }

    Write-Host "  [files] [OK] all copies complete." -ForegroundColor Green
}
