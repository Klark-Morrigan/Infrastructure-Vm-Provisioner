<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1 and by
    scripts\Test-HostNetworkPreflight.ps1.
#>

# ---------------------------------------------------------------------------
# Test-InternetRouteThroughWan
#   Preflight check 8: Windows sends internet traffic out through the adapter
#   ICS shares. ICS NATs the VMs' traffic only out of that WAN adapter, so when
#   another interface carries the internet route - most often a VPN, which
#   holds the default route ahead of Wi-Fi - the VMs have no way out while the
#   host itself stays online. Every other check passes in that state, the ICS
#   DNS probe included, because the host resolves through its own working path.
#
#   Report-only, even under auto-repair: disconnecting a VPN is the operator's
#   call. -AllowOtherInternetRoute downgrades the FAIL to a WARN for a false
#   positive, so the finding stays visible without blocking the run.
# ---------------------------------------------------------------------------

function Test-InternetRouteThroughWan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        # The ICS-shared (WAN) adapter's name; empty when the caller knows none.
        [string] $WanAdapterName,

        # The route half of Find-NetRoute's answer for a public address; $null
        # when the host has no route to it.
        [object] $InternetRoute,

        [switch] $AllowOtherInternetRoute
    )

    if (-not $WanAdapterName) {
        return [PSCustomObject]@{
            Status = 'WARN'
            Label = 'Internet route leaves via the WAN adapter'
            Detail = 'Skipped: no WAN adapter named. Pass -WanAdapterName to compare.'
        }
    }

    $label = "Internet route leaves via WAN adapter '$WanAdapterName'"
    $overrideHint = 'A false positive: re-run with -AllowOtherInternetRoute.'
    $overrideNotice = 'Allowed by -AllowOtherInternetRoute, so VM egress may fail.'
    $blockedStatus = $AllowOtherInternetRoute ? 'WARN' : 'FAIL'

    if (-not $InternetRoute) {

        $cause = 'The host has no route to the internet'

        $detail = $AllowOtherInternetRoute `
            ? "$cause. $overrideNotice" `
            : "$cause, so neither it nor the VMs can reach out. " +
                "Connect '$WanAdapterName' to a network. $overrideHint"

        return [PSCustomObject]@{
            Status = $blockedStatus
            Label = $label
            Detail = $detail }
    }

    if ($InternetRoute.InterfaceAlias -ne $WanAdapterName) {

        $cause = "Windows sends internet traffic via '$($InternetRoute.InterfaceAlias)'"

        $detail = $AllowOtherInternetRoute `
            ? "$cause. $overrideNotice" `
            : "$cause, so ICS cannot carry the VMs' traffic out. A VPN: disconnect it. " +
                "Another adapter: share that one through ICS instead. $overrideHint"

        return [PSCustomObject]@{
            Status = $blockedStatus
            Label = $label
            Detail = $detail }
    }

    [PSCustomObject]@{
        Status = 'PASS'
        Label = $label
        Detail = "next hop $($InternetRoute.NextHop)"
    }
}
