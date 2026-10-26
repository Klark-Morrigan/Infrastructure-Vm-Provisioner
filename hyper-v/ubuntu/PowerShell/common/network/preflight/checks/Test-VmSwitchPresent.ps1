<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1 and by
    scripts\Test-HostNetworkPreflight.ps1.
#>

# ---------------------------------------------------------------------------
# Test-VmSwitchPresent
#   Preflight check 1: the named switch exists. Takes the already-fetched
#   switch object rather than looking it up, so the orchestrator queries
#   Hyper-V once and every check reads the same snapshot.
#
#   A FAIL here ends the preflight: every check after it reads the switch or
#   its vEthernet, so continuing would bury one real cause under a cascade of
#   consequences.
# ---------------------------------------------------------------------------

function Test-VmSwitchPresent {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $SwitchName,

        # Result of Get-VMSwitch for $SwitchName; $null when it is missing.
        [object] $Switch
    )

    if (-not $Switch) {
        return [PSCustomObject]@{
            Status = 'FAIL'
            Label  = "VMSwitch '$SwitchName' exists"
            Detail = "Switch is missing. Expected to have been created by Initialize-ExternalSwitch, OR (if you migrated from External to Internal+ICS earlier) the switch was torn down by a Hyper-V service restart / Windows update. Recreate via: New-VMSwitch -Name '$SwitchName' -SwitchType Internal  (then re-enable ICS on WiFi -> vEthernet)."
        }
    }

    [PSCustomObject]@{
        Status = 'PASS'
        Label  = "VMSwitch '$SwitchName' exists"
        Detail = "SwitchType=$($Switch.SwitchType)"
    }
}
