<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1 and
    by Assert-HostNetworkPreflight (the auto-repair path).
#>

# ---------------------------------------------------------------------------
# Reset-IcsSharing
#   Programmatic equivalent of the GUI "uncheck -> re-check the Sharing
#   checkbox on the WiFi adapter" gesture: the canonical kick that
#   makes ICS rebind its DNS proxy + NAT mappings + auto-generated
#   firewall rules. Uses the HNetCfg.HNetShare COM API - the same
#   surface the Sharing tab calls into - so it tears down and rebuilds
#   the persisted ICS config, not just bounces the SharedAccess
#   service.
#
#   Why this matters: Restart-Service SharedAccess re-reads the same
#   persisted state, including whatever broke it. The COM teardown
#   (DisableSharing) wipes the "shared" attribute on the WAN adapter,
#   releases ICS's UDP/53 listener on the LAN adapter, and clears
#   NAT state - re-EnableSharing rebuilds all of that from scratch.
#
#   Failure mode this defends against (seen 2026-06): ICS DNS proxy
#   answers UDP/53 queries with TCP RSTs to the VM, host-side
#   Resolve-DnsName -Server 192.168.137.1 returns "An existing
#   connection was forcibly closed". Toggling sharing fixes it
#   every time; a service restart does not.
# ---------------------------------------------------------------------------

function Reset-IcsSharing {
    [CmdletBinding()]
    param(
        # WAN-side interface (the one with internet). e.g. 'Wi-Fi'.
        # This is the connection whose Sharing tab checkbox we are
        # effectively toggling.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $WanInterfaceName,

        # LAN-side interface (the ICS-served network). e.g.
        # 'vEthernet (ExternalSwitch-Shared)'. This is the
        # connection ICS shares INTO.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $LanInterfaceName
    )

    # HNetCfg.HNetShare is the COM surface Windows uses for ICS
    # itself. EnumEveryConnection returns each NetConnection; for
    # each, NetConnectionProps gives us the visible name to match
    # on, and INetSharingConfigurationForINetConnection gives us
    # the Enable/Disable methods.
    $hnetcfg = New-Object -ComObject HNetCfg.HNetShare

    $wanCfg = $null
    $lanCfg = $null
    foreach ($conn in $hnetcfg.EnumEveryConnection) {
        $name = $hnetcfg.NetConnectionProps.Invoke($conn).Name
        if ($name -eq $WanInterfaceName) {
            $wanCfg = $hnetcfg.INetSharingConfigurationForINetConnection.Invoke($conn)
        }
        elseif ($name -eq $LanInterfaceName) {
            $lanCfg = $hnetcfg.INetSharingConfigurationForINetConnection.Invoke($conn)
        }
    }

    if (-not $wanCfg) {
        throw "Reset-IcsSharing: WAN interface '$WanInterfaceName' not found via HNetCfg. Run Get-NetAdapter to confirm the name."
    }
    if (-not $lanCfg) {
        throw "Reset-IcsSharing: LAN interface '$LanInterfaceName' not found via HNetCfg. Run Get-NetAdapter to confirm the name."
    }

    # Tear down first (matches GUI uncheck). Idempotent - DisableSharing
    # is safe even when sharing was already off, so we don't bother
    # branching on SharingEnabled.
    if ($wanCfg.SharingEnabled) { $wanCfg.DisableSharing() }
    if ($lanCfg.SharingEnabled) { $lanCfg.DisableSharing() }

    # Rebuild. The constants ICSSHARINGTYPE are:
    #   0 = ICSSHARINGTYPE_PUBLIC  (the WAN side, gets to share)
    #   1 = ICSSHARINGTYPE_PRIVATE (the LAN side, gets shared into)
    $wanCfg.EnableSharing(0)
    $lanCfg.EnableSharing(1)
}
