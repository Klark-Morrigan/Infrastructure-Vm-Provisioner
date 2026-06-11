<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1.
#>

# ---------------------------------------------------------------------------
# Set-RouterSshPortProxy
#   Ensures a host-side netsh portproxy rule forwarding
#   <ListenAddress>:<ListenPort> (typically 127.0.0.1:2222) to
#   <ConnectAddress>:<ConnectPort> (the router VM's SSH endpoint).
#   Idempotent: parses the existing v4tov4 rules and skips when a
#   matching rule already exists; deletes-and-re-adds when the
#   connect target has changed; adds-fresh when absent.
#
#   Why this matters: WSL2 runs as a separate Hyper-V guest with its
#   own NAT subnet. Outbound from WSL to the host's Internal-vSwitch
#   subnet (e.g. 192.168.137.0/24, the ICS-served network) is not
#   forwarded by default - ICS NAT is set up for WSL -> Internet via
#   the WAN, not WSL -> peer VM via the LAN side. A localhost port
#   proxy on the host turns the cross-subnet hop into a same-host
#   loopback that WSL can always reach. Ansible's ProxyCommand
#   (sshpass + ssh routeradmin@<host-port>) then succeeds.
#
#   Persists across reboots (netsh portproxy state lives in
#   HKLM\SYSTEM\CurrentControlSet\Services\PortProxy). Safe to run
#   every provisioning attempt because of the idempotency check.
# ---------------------------------------------------------------------------

function Set-RouterSshPortProxy {
    [CmdletBinding()]
    param(
        # Host-side listen target. 0.0.0.0 (all interfaces) is the
        # default because WSL2 in default NAT mode cannot reach the
        # host's 127.0.0.1 - from inside WSL, `127.0.0.1` is WSL's
        # own loopback, NOT the host's. WSL can reach the host on
        # its WSL-side vEthernet IP, which 0.0.0.0 covers. Operators
        # who don't need WSL access can pin it back to 127.0.0.1 for
        # tighter isolation. Windows Firewall still gates inbound on
        # 2222 - the LAN-facing surface is only as open as the
        # firewall profile allows.
        [string] $ListenAddress = '0.0.0.0',

        [int]    $ListenPort    = 2222,

        # Router VM's reachable IP on the host's Internal vSwitch
        # (typically the routerExternalIp from secret.json).
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ConnectAddress,

        [int]    $ConnectPort   = 22
    )

    $existing = Get-NetshPortProxyRules |
                Where-Object {
                    $_.ListenAddress -eq $ListenAddress -and
                    $_.ListenPort    -eq $ListenPort
                } | Select-Object -First 1

    if ($existing) {
        if ($existing.ConnectAddress -eq $ConnectAddress -and
            $existing.ConnectPort    -eq $ConnectPort) {
            Write-Host ("  [portproxy] {0}:{1} -> {2}:{3} already present, skipping." -f `
                $ListenAddress, $ListenPort, $ConnectAddress, $ConnectPort)
            return
        }
        Write-Host ("  [portproxy] {0}:{1} currently forwards to {2}:{3}; replacing with {4}:{5}." -f `
            $ListenAddress, $ListenPort,
            $existing.ConnectAddress, $existing.ConnectPort,
            $ConnectAddress, $ConnectPort)
        & netsh interface portproxy delete v4tov4 `
            listenaddress=$ListenAddress listenport=$ListenPort | Out-Null
    } else {
        Write-Host ("  [portproxy] adding {0}:{1} -> {2}:{3}" -f `
            $ListenAddress, $ListenPort, $ConnectAddress, $ConnectPort)
    }

    & netsh interface portproxy add v4tov4 `
        listenaddress=$ListenAddress listenport=$ListenPort `
        connectaddress=$ConnectAddress connectport=$ConnectPort | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "netsh interface portproxy add failed with exit $LASTEXITCODE for ${ListenAddress}:${ListenPort} -> ${ConnectAddress}:${ConnectPort}."
    }
}
