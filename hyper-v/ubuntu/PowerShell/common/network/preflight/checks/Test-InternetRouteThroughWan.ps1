<#
.NOTES
    Do not run this file directly. Dot-sourced by Import-PreflightFunctions.ps1.
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
#   call. -AllowInternetRouteFault downgrades the FAIL to a WARN for a false
#   positive, so the finding stays visible without blocking the run.
# ---------------------------------------------------------------------------

function Test-InternetRouteThroughWan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        # The ICS-shared (WAN) adapter's name; empty when the caller knows none.
        [string] $WanAdapterName,

        # Get-InternetRoute's answer; $null when the host has no route out.
        [object] $InternetRoute,

        [switch] $AllowInternetRouteFault
    )

    if (-not $WanAdapterName) {
        return New-PreflightFinding `
            -Status WARN `
            -Label 'Internet route leaves via the WAN adapter' `
            -Detail 'Skipped: no WAN adapter named. Pass -WanAdapterName to compare.'
    }

    $label = "Internet route leaves via WAN adapter '$WanAdapterName'"

    # What is wrong, and what follows from it with the way to fix it.
    $fault = $null
    $consequence = $null

    if (-not $InternetRoute) {

        $fault = 'The host has no route to the internet'

        $consequence =
            "so neither it nor the VMs can reach out. " +
            "Connect '$WanAdapterName' to a network."
    }
    elseif ($InternetRoute.InterfaceAlias -ne $WanAdapterName) {

        $fault = "Windows sends internet traffic via '$($InternetRoute.InterfaceAlias)'"

        $consequence =
            "so ICS cannot carry the VMs' traffic out. " +
            "A VPN: disconnect it. " +
            "Another adapter: share that one through ICS instead."
    }

    if (-not $fault) {
        return New-PreflightFinding `
            -Status PASS `
            -Label $label `
            -Detail "next hop $($InternetRoute.NextHop)"
    }

    if ($AllowInternetRouteFault) {
        return New-PreflightFinding `
            -Status WARN `
            -Label $label `
            -Detail "$fault. Allowed by -AllowInternetRouteFault, so VM egress may fail."
    }

    New-PreflightFinding `
        -Status FAIL `
        -Label $label `
        -Detail "$fault, $consequence A false positive: re-run with -AllowInternetRouteFault."
}
