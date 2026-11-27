<#
.NOTES
    Do not run this file directly. Dot-sourced by Import-PreflightFunctions.ps1.
#>

# ---------------------------------------------------------------------------
# Get-IcsHostAddress
#   The address Windows Internet Connection Sharing gives the host side of the
#   network it shares into. ICS hardcodes it, so it is also where the VMs'
#   router finds its gateway and DNS proxy. Held in one place because the
#   preflight both checks the host vNIC against it and probes DNS on it.
# ---------------------------------------------------------------------------

function Get-IcsHostAddress {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    '192.168.137.1'
}
