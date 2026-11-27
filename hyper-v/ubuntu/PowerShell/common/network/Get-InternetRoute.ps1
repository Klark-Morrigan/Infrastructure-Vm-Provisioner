<#
.NOTES
    Do not run this file directly. Dot-sourced by Import-PreflightFunctions.ps1.
#>

# ---------------------------------------------------------------------------
# Get-InternetRoute
#   The route Windows would use to reach the internet, or nothing when it has
#   none. Asking Windows, rather than reading the default route, is what
#   catches a VPN: one that installs two half-default routes (0.0.0.0/1 and
#   128.0.0.0/1) has no 0.0.0.0/0 entry to find, yet still carries the traffic.
#
#   Find-NetRoute answers with two objects, the source address and then the
#   route. Only the route carries NextHop, which is how it is picked out here
#   so that no caller has to know the pair exists.
# ---------------------------------------------------------------------------

function Get-InternetRoute {
    [CmdletBinding()]
    [OutputType([object])]
    param()

    # Any public address works: only the interface chosen for it matters.
    $publicAddress = '1.1.1.1'

    Find-NetRoute `
        -RemoteIPAddress $publicAddress `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['NextHop'] } |
        Select-Object -First 1
}
