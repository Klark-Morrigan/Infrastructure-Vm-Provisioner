<#
.NOTES
    Do not run this file directly. Dot-sourced by Import-PreflightFunctions.ps1.
#>

# ---------------------------------------------------------------------------
# Test-ConnectedRouteToSubnet
#   Preflight check 4: the host has a connected route to the vNIC's own subnet
#   VIA that vNIC. Without it the host sends VM-subnet traffic to its default
#   gateway - the Wi-Fi one - which is the "SourceAddress=WiFi" symptom from
#   the ICS migration: every probe leaves by the wrong interface and the VM
#   never answers.
#
#   Silent when the vNIC has no IPv4: there is no subnet to route to yet, and
#   check 2 has already reported the missing address as the actual fault.
# ---------------------------------------------------------------------------

function Test-ConnectedRouteToSubnet {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Alias,

        # Get-NetIPAddress result for $Alias; $null when it has no IPv4.
        [object] $IpAddress
    )

    if (-not $IpAddress) {
        return
    }

    $subnet = ($IpAddress.IPAddress -replace '\.\d+$', '.0') + "/$($IpAddress.PrefixLength)"
    $label = "Connected route $subnet via $Alias"

    $route = Get-NetRoute `
        -DestinationPrefix $subnet `
        -ErrorAction SilentlyContinue |
        Where-Object InterfaceAlias -eq $Alias

    if (-not $route) {
        return New-PreflightFinding `
            -Status FAIL `
            -Label $label `
            -Detail (
                "Route missing. " +
                "Host will route VM traffic out the wrong interface (likely WiFi default route).")
    }

    $first = @($route)[0]

    New-PreflightFinding `
        -Status PASS `
        -Label $label `
        -Detail "metric $($first.RouteMetric)+$($first.InterfaceMetric)"
}
