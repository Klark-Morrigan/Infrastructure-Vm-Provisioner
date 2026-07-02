<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1 alongside the other up/seed/* helpers.
#>

# ---------------------------------------------------------------------------
# Initialize-SeedConfigDirectory
#   Idempotently ensures the per-VM config path exists before the seed ISO
#   is written into it. Shared by the workload and router seed generators
#   so the bootstrap logic lives in one place.
# ---------------------------------------------------------------------------
function Initialize-SeedConfigDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    if (-not (Test-Path -Path $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        Write-Host "  Created directory: $Path"
    }
}
