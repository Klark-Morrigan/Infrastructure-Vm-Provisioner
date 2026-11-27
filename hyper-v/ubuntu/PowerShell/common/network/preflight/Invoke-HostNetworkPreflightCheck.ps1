<#
.NOTES
    Do not run this file directly. Dot-sourced by Import-PreflightFunctions.ps1.
#>

# ---------------------------------------------------------------------------
# Invoke-HostNetworkPreflightCheck
#   The manual run of the host network preflight: what
#   scripts\Test-HostNetworkPreflight.ps1 does once its modules are loaded.
#   Returns an exit code, 0 for a clean host and 1 for any FAIL, so the script
#   stays composable with shell pipelines and CI.
#
#   Read-only unless -AutoRepair is given: an operator running it by hand may
#   have VMs alive that would lose their default route during an ICS toggle.
#
#   After a repair run it re-lays the controller -> router SSH relay. The ICS
#   toggle regenerates the Internal vSwitch network, which leaves the persisted
#   portproxy bound to the old one: the controller still reaches the host
#   listener, and the onward hop to the router dies. The re-lay is an
#   idempotent delete and re-add, so it is harmless when no toggle fired.
#
#   Whatever the preflight and the re-lay emit is piped to the console: left
#   on the output stream it would join the exit code as this function's
#   return value.
# ---------------------------------------------------------------------------

function Invoke-HostNetworkPreflightCheck {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        # Matches the provisioner config's externalSwitchName.
        [string] $SwitchName = 'ExternalSwitch-Shared',

        # Where the DNS-via-ICS check probes. Empty skips that check.
        [string] $DnsProbeTarget = (Get-IcsHostAddress),

        # Empty lets Resolve-WanAdapterName find the adapter.
        [string] $WanAdapterName,

        # The router VM's static address on the ICS network, where the relay
        # is re-laid after a repair. Empty skips the re-lay, for a host with
        # no router VM.
        [string] $RouterAddress = '192.168.137.11',

        [switch] $AutoRepair,

        [switch] $AllowInternetRouteFault
    )

    $resolvedWanAdapterName = Resolve-WanAdapterName -WanAdapterName $WanAdapterName

    try {

        Assert-HostNetworkPreflight `
            -SwitchName $SwitchName `
            -DnsProbeTarget $DnsProbeTarget `
            -WanAdapterName $resolvedWanAdapterName `
            -NoAutoRepair:(-not $AutoRepair) `
            -AllowInternetRouteFault:$AllowInternetRouteFault |
            Out-Host

        if ($AutoRepair `
                -and $RouterAddress) {

            Write-Host ""
            Write-Host (
                "Refreshing controller -> router SSH relay (-> ${RouterAddress}:22) " +
                "after host-network repair ...") `
                -ForegroundColor Cyan

            Set-RouterSshRelay -ConnectAddress $RouterAddress |
                Out-Host
        }

        Write-Host ""
        Write-Host `
            "Summary: host network preflight OK." `
            -ForegroundColor Green

        return 0
    }
    catch {

        Write-Host ""
        Write-Host `
            $_.Exception.Message `
            -ForegroundColor Red

        return 1
    }
}
