<#
.SYNOPSIS
    Runs SSH integration tests against a Docker target container.

.DESCRIPTION
    Delegates to the canonical implementation in Common-PowerShell
    (expected as a sibling checkout under the same parent directory).
    Requires Docker Desktop (Linux containers) to be running.

.EXAMPLE
    .\Run-IntegrationTests-AgainstDockerTarget.ps1
#>

# Repo root is one level up now that this script lives under scripts\;
# Common-PowerShell is a sibling of the repo root, and its copy of this
# script also lives under scripts\ after the recent migration.
$repoRoot = Split-Path -Parent $PSScriptRoot

& ([IO.Path]::Combine($repoRoot, '..', 'Common-PowerShell', 'scripts', `
    'Run-IntegrationTests-AgainstDockerTarget.ps1')) -TestsRoot $repoRoot
