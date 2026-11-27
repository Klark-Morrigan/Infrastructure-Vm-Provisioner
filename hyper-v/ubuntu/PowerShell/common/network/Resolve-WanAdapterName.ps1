<#
.NOTES
    Do not run this file directly. Dot-sourced by Import-PreflightFunctions.ps1.
#>

# ---------------------------------------------------------------------------
# Resolve-WanAdapterName
#   The name of the internet-facing (WAN) adapter ICS shares: the operator's
#   own choice when given, else the wireless adapter that is Up.
#
#   Detected rather than defaulted because the connection name varies by host
#   ('Wi-Fi', 'Wi-Fi 2', a vendor name), and a wrong one fails deep in the ICS
#   COM call with a bare "interface not found". Says what it found, and lists
#   the candidates when it finds none, so the operator can name the adapter.
#
#   Read-only, so it is safe on a run that repairs nothing.
# ---------------------------------------------------------------------------

function Resolve-WanAdapterName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # The operator's own choice; returned as given.
        [string] $WanAdapterName
    )

    if ($WanAdapterName) {
        return $WanAdapterName
    }

    $wifiAdapter = Get-WirelessNetAdapter |
        Where-Object { $_.Status -eq 'Up' } |
        Select-Object -First 1

    if ($wifiAdapter) {

        Write-Host (
            "WAN adapter auto-detected for the ICS checks: '$($wifiAdapter.Name)' " +
            "($($wifiAdapter.InterfaceDescription)).") `
            -ForegroundColor Cyan

        return $wifiAdapter.Name
    }

    $physical = Get-NetAdapter `
        -Physical `
        -ErrorAction SilentlyContinue |
        Sort-Object Name |
        ForEach-Object { "$($_.Name) [$($_.Status)]" }

    Write-Host `
        "Could not auto-detect an Up wireless adapter for the ICS checks." `
        -ForegroundColor Yellow
    Write-Host `
        "Physical adapters present: $($physical -join ', ')" `
        -ForegroundColor Yellow
    Write-Host `
        "Re-run with -WanAdapterName '<your internet-facing connection>'." `
        -ForegroundColor Yellow
}
