<#
.SYNOPSIS
    Runs SSH integration tests against a Docker target container.

.DESCRIPTION
    Delegates to the canonical implementation in PowerShell-Common
    (expected as a sibling checkout under the same parent directory).
    Requires Docker Desktop (Linux containers) to be running.

.EXAMPLE
    .\Run-IntegrationTests-AgainstDockerTarget.ps1
#>

# Repo root is one level up now that this script lives under scripts\;
# PowerShell-Common is a sibling of the repo root, and its copy of this
# script also lives under scripts\ after the recent migration.
$repoRoot = Split-Path -Parent $PSScriptRoot

& ([IO.Path]::Combine($repoRoot, '..', 'PowerShell-Common', 'scripts', `
    'Run-IntegrationTests-AgainstDockerTarget.ps1')) -TestsRoot $repoRoot
