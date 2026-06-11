<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1.
#>

# ---------------------------------------------------------------------------
# Test-HostNetworkProfileSetting
#   Preflight check 6: vEthernet's Windows network profile must be
#   Private (or Domain). Public blocks ICS's auto-generated DNS-In
#   firewall rule and VM DNS queries silently drop.
#
#   Only relevant on Internal (ICS) switches; the caller is expected
#   to gate the call. Returns a finding object describing PASS/FAIL
#   (orchestrator calls Add-Finding on it), or $null when the
#   profile cannot be queried at all (treat as not-applicable - the
#   absent-vEthernet case is already handled by check 2).
#
#   "Only toggle when Public": when current is Private/Domain we
#   stay quiet (return PASS without calling Set-NetConnectionProfile),
#   so re-runs of the preflight never redundantly mutate state.
# ---------------------------------------------------------------------------

function Test-HostNetworkProfileSetting {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $InterfaceAlias,

        # When set, do not auto-repair. A Public profile is reported
        # as FAIL with a copy-paste fix command instead.
        [switch] $NoAutoRepair
    )

    $netProfile = Get-NetConnectionProfile -InterfaceAlias $InterfaceAlias `
                                           -ErrorAction SilentlyContinue
    if (-not $netProfile) { return $null }

    if ($netProfile.NetworkCategory -ne 'Public') {
        return [PSCustomObject]@{
            Status = 'PASS'
            Label  = "vEthernet profile = Private"
            Detail = "Current=$($netProfile.NetworkCategory). ICS DNS-In permitted."
        }
    }

    if ($NoAutoRepair) {
        return [PSCustomObject]@{
            Status = 'FAIL'
            Label  = "vEthernet profile = Private (not Public)"
            Detail = "Current=Public. Blocks ICS's DNS-In firewall rule so VM DNS queries silently drop. Run Set-NetConnectionProfile -InterfaceAlias '$InterfaceAlias' -NetworkCategory Private (or re-run preflight without -NoAutoRepair)."
        }
    }

    Set-NetConnectionProfile -InterfaceAlias $InterfaceAlias `
                             -NetworkCategory Private
    return [PSCustomObject]@{
        Status = 'PASS'
        Label  = "vEthernet profile = Private (auto-repaired)"
        Detail = "Was Public; switched to Private so ICS's DNS-In rule applies."
    }
}
