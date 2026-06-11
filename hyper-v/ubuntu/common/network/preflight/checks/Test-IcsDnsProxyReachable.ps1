<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1.
#>

# ---------------------------------------------------------------------------
# Test-IcsDnsProxyReachable
#   Preflight check 7: the exact DNS path the VM is about to use -
#   libc -> systemd-resolved stub -> ICS DNS proxy (LAN-side
#   vEthernet IP) -> host's WiFi DNS. Probes against
#   archive.ubuntu.com because the package the seed needs (dnsmasq)
#   resolves there; success means cloud-init's apt phase has a
#   working name service before we even create the VM.
#
#   Auto-repair on probe FAIL is bounded to a SINGLE Reset-IcsSharing
#   attempt + one re-probe. If the re-probe also fails it is a
#   genuine ICS bug, not a transient state flap; the operator gets
#   one clear FAIL with the next steps in Detail, not a retry
#   spiral. Returns a finding object; orchestrator routes to
#   Add-Finding.
#
#   ICS's DNS proxy is known to enter a broken state where it
#   answers UDP/53 with TCP RSTs (host-side Resolve-DnsName -Server
#   192.168.137.1 returns "An existing connection was forcibly
#   closed"). Restart-Service SharedAccess does NOT recover from
#   this; the canonical fix is to toggle the WiFi adapter's Sharing
#   checkbox off + on, which Reset-IcsSharing automates via the
#   HNetCfg COM API.
# ---------------------------------------------------------------------------

function Test-IcsDnsProxyReachable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $DnsProbeTarget,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $LanAdapterName,

        # When omitted, auto-repair is skipped even on probe FAIL
        # (Reset-IcsSharing needs to know which connection is
        # actually shared, and we will not guess from the LAN side
        # alone).
        [string] $WanAdapterName,

        [switch] $NoAutoRepair
    )

    if (Test-IcsDnsReachable -Server $DnsProbeTarget) {
        return [PSCustomObject]@{
            Status = 'PASS'
            Label  = "ICS DNS proxy answers at $DnsProbeTarget"
            Detail = "Resolve-DnsName archive.ubuntu.com succeeded against the ICS gateway."
        }
    }

    if ($NoAutoRepair -or -not $WanAdapterName) {
        $hint = if ($NoAutoRepair) {
            "Auto-repair disabled by -NoAutoRepair."
        } else {
            "WanAdapterName not supplied so auto-repair is skipped."
        }
        return [PSCustomObject]@{
            Status = 'FAIL'
            Label  = "ICS DNS proxy answers at $DnsProbeTarget"
            Detail = "Resolve-DnsName archive.ubuntu.com -Server $DnsProbeTarget failed. $hint Toggle ICS sharing manually (WiFi adapter -> Sharing tab -> uncheck -> re-check) and re-run."
        }
    }

    try {
        Reset-IcsSharing -WanInterfaceName $WanAdapterName `
                         -LanInterfaceName $LanAdapterName
    } catch {
        return [PSCustomObject]@{
            Status = 'FAIL'
            Label  = "ICS DNS proxy answers at $DnsProbeTarget"
            Detail = "Resolve-DnsName failed; Reset-IcsSharing also failed: $($_.Exception.Message)"
        }
    }

    if (Test-IcsDnsReachable -Server $DnsProbeTarget) {
        return [PSCustomObject]@{
            Status = 'PASS'
            Label  = "ICS DNS proxy answers at $DnsProbeTarget (auto-repaired)"
            Detail = "Initial probe failed; Reset-IcsSharing kicked the proxy; re-probe succeeded."
        }
    }

    return [PSCustomObject]@{
        Status = 'FAIL'
        Label  = "ICS DNS proxy answers at $DnsProbeTarget"
        Detail = "Probe failed and stayed failing after Reset-IcsSharing. Genuine ICS bug - check Get-Service SharedAccess + Windows firewall rules for 'Internet Connection Sharing'."
    }
}
