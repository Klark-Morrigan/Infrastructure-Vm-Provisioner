<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1 and by
    scripts\Test-HostNetworkPreflight.ps1.
#>

# ---------------------------------------------------------------------------
# Test-HostVNicReady
#   Preflight check 2: the host's vEthernet for the switch is Up and carries
#   an IPv4. Two findings rather than one, because the causes differ: a
#   missing or Down vNIC means switch creation did not finish, while a vNIC
#   that is Up with no address means ICS flipped off or DHCP never bound.
#
#   Reports on the address even when the adapter is missing, so the operator
#   sees the whole picture in one pass instead of re-running to discover the
#   next consequence.
# ---------------------------------------------------------------------------

function Test-HostVNicReady {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Alias,

        # Get-NetAdapter result for $Alias; $null when absent.
        [object] $Adapter,

        # Get-NetIPAddress result for $Alias; $null when it has no IPv4.
        [object] $IpAddress
    )

    if (-not $Adapter) {
        [PSCustomObject]@{
            Status = 'FAIL'
            Label  = "Host vNIC '$Alias' present"
            Detail = "vEthernet missing. Did switch creation finish?"
        }
    } elseif ($Adapter.Status -ne 'Up') {
        [PSCustomObject]@{
            Status = 'FAIL'
            Label  = "Host vNIC '$Alias' status"
            Detail = "Status=$($Adapter.Status). Bring it Up or recreate the switch."
        }
    } else {
        [PSCustomObject]@{
            Status = 'PASS'
            Label  = "Host vNIC '$Alias' is Up"
            Detail = "MAC=$($Adapter.MacAddress)"
        }
    }

    if (-not $IpAddress) {
        [PSCustomObject]@{
            Status = 'FAIL'
            Label  = "Host vNIC has IPv4"
            Detail = "No IPv4 on '$Alias'. ICS may have flipped off, or DHCP has not bound."
        }
    } else {
        [PSCustomObject]@{
            Status = 'PASS'
            Label  = "Host vNIC has IPv4"
            Detail = "$($IpAddress.IPAddress)/$($IpAddress.PrefixLength) ($($IpAddress.PrefixOrigin))"
        }
    }
}
