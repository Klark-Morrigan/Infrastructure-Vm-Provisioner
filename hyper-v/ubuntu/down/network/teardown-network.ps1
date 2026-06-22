<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    deprovision.ps1, which is responsible for also dot-sourcing
    common/network/Remove-LegacySingletonNat.ps1 so the shared cleanup
    helper is in scope when this function runs.
#>

# ---------------------------------------------------------------------------
# Invoke-NetworkTeardown
#   Per-environment idempotent teardown of the Hyper-V networking objects an
#   environment owns: the per-environment Private switch and any leftover
#   singleton-NAT state at the environment's gateway IP.
#
#   Composed of three pieces:
#     1. Legacy singleton-NAT cleanup (NetNat + host vNIC IP) via the shared
#        Remove-LegacySingletonNat helper. Same code path the provision
#        side runs, so a deprovision / re-provision cycle leaves no
#        legacy state behind.
#     2. Host-side SSH portproxy relay + its firewall companion removal -
#        the teardown counterpart to provision's Set-RouterSshPortProxy /
#        Set-RouterSshPortProxyFirewall (Infrastructure.Network.Windows).
#        netsh portproxy state persists across VM/switch teardown, so
#        without this the relay accumulates per router IP across lifecycles
#        and a stale entry can shadow the next router's WSL relay
#        auto-discovery. Skipped when no router external IP is known.
#     3. Private switch removal, guarded by an attached-VMs check. VMs
#        outside the config that are still connected (e.g. provisioned by
#        another lifecycle) keep their network; the teardown logs and
#        leaves the switch in place.
# ---------------------------------------------------------------------------
function Invoke-NetworkTeardown {
    [CmdletBinding()]
    param(
        # The environment's Hyper-V Private switch. Removed when no VMs are
        # still attached. May not exist - absence is logged, not an error.
        [Parameter(Mandatory)]
        [string] $PrivateSwitchName,

        # The environment's gateway IP. In the new world this is the router
        # VM's privateIpAddress; in the legacy world it was the host vNIC
        # IP. Either way, any NetNat covering it and any host vNIC carrying
        # it gets removed via the shared cleanup helper.
        [Parameter(Mandatory)]
        [string] $GatewayIp,

        # The router VM's external (Internal-vSwitch) IP - the connect
        # target of the host-side SSH portproxy relay provision set up for
        # WSL-based Ansible. Optional: legacy / workload-only environments
        # and DHCP routers (no config-time external IP) pass nothing, and
        # the portproxy + firewall removal is skipped.
        [Parameter()]
        [string] $RouterExternalIp,

        # Listen port of the portproxy relay and its firewall rule. Matches
        # Set-RouterSshPortProxy's default; only consulted when
        # $RouterExternalIp is supplied.
        [Parameter()]
        [int] $PortProxyListenPort = 2222
    )

    Write-Host ""
    Write-Host "--- Network teardown: $PrivateSwitchName ($GatewayIp) ---" `
        -ForegroundColor Cyan

    Remove-LegacySingletonNat -GatewayIp $GatewayIp

    # ------------------------------------------------------------------
    # Host-side SSH portproxy relay + firewall companion (the teardown
    # counterpart to provision's Set-RouterSshPortProxy /
    # Set-RouterSshPortProxyFirewall). netsh portproxy state survives
    # VM/switch teardown, so removing it here is what stops relays
    # accumulating per router IP across lifecycles. Both removers are
    # idempotent. Skipped when no router external IP is known.
    # ------------------------------------------------------------------
    if ($RouterExternalIp) {
        Remove-RouterSshPortProxy -ConnectAddress $RouterExternalIp
        Remove-RouterSshPortProxyFirewall -ListenPort $PortProxyListenPort
    }

    # ------------------------------------------------------------------
    # Private switch removal (guarded by attached-VMs check)
    # Pipe Get-VM into Get-VMNetworkAdapter so only adapters belonging to
    # currently existing VMs are considered. Get-VMNetworkAdapter -All is
    # intentionally avoided here: VMMS deregisters adapters asynchronously
    # after Remove-VM returns, so -All transiently reports adapters for
    # VMs that have already been removed, causing teardown to be skipped
    # incorrectly.
    # ------------------------------------------------------------------
    $remainingAdapters = @(
        Get-VM -ErrorAction SilentlyContinue |
            Get-VMNetworkAdapter -ErrorAction SilentlyContinue |
            Where-Object { $_.SwitchName -eq $PrivateSwitchName }
    )

    if ($remainingAdapters.Count -gt 0) {
        Write-Host (
            "  $($remainingAdapters.Count) VM(s) still connected to " +
            "'$PrivateSwitchName' - skipping switch removal."
        ) -ForegroundColor Yellow
    }
    else {
        $existingSwitch = Get-VMSwitch -Name $PrivateSwitchName `
                                       -ErrorAction SilentlyContinue
        if ($null -ne $existingSwitch) {
            Write-Host "  Removing virtual switch '$PrivateSwitchName' ..."
            Remove-VMSwitch -Name $PrivateSwitchName -Force
            Write-Host "  [OK] Virtual switch removed." -ForegroundColor Green
        }
        else {
            Write-Host "  Virtual switch '$PrivateSwitchName' not found - skipping." `
                -ForegroundColor Yellow
        }
    }

    Write-Host "  [OK] Network teardown complete." -ForegroundColor Green
}
