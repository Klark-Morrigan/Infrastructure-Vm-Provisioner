<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1 alongside
    the other common/ssh helpers.
#>

# ---------------------------------------------------------------------------
# Test-SshBanner
#   Connects to <IpAddress>:<Port>, reads up to a few bytes, and returns
#   $true iff the bytes start with the SSH protocol banner prefix ("SSH-").
#   Returns $false on TCP connect failure, timeout, or a non-SSH response.
#
#   Why this beats a bare TCP probe through a tunnel:
#     - SSH.NET's ForwardedPortLocal listener accepts the TCP socket the
#       moment ForwardedPortLocal.Start() returns. A TCP-only probe
#       therefore succeeds INSTANTLY against a tunnel whose far end may
#       not have sshd running yet - the listener accepts, SSH.NET tries
#       to open the direct-tcpip channel, the channel-open fails because
#       the workload's port 22 is silent, SSH.NET tears the local socket
#       down a few hundred ms later - by which time the caller already
#       believed the probe succeeded and moved on.
#     - The SSH banner is the first thing the SERVER sends after the TCP
#       3-way handshake. If we receive it, SSH.NET successfully opened
#       the channel AND the workload's sshd is actually serving on the
#       far side. If the connection drops without sending the banner,
#       the workload is not yet ready.
#
#   The 16-byte read is a conservative ceiling - the OpenSSH banner is
#   typically ~24 bytes ("SSH-2.0-OpenSSH_9.6p1\r\n"), and we only need
#   the first 4 bytes ("SSH-") to confirm protocol speaker. Reading more
#   would only delay the success path.
# ---------------------------------------------------------------------------
function Test-SshBanner {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $IpAddress,

        [Parameter()]
        [int] $Port = 22,

        # Total banner-read budget (connect + read). 3 s comfortably
        # covers a local-LAN SSH banner; through a tunnel with a slow
        # far end, the connection drops fast on channel-open failure
        # so this timeout primarily caps the "server is up but quiet"
        # pathology, not normal operation.
        [Parameter()]
        [int] $TimeoutMilliseconds = 3000
    )

    $tcpClient = $null
    try {
        $tcpClient = [System.Net.Sockets.TcpClient]::new()
        $connectTask = $tcpClient.ConnectAsync($IpAddress, $Port)
        if (-not $connectTask.Wait($TimeoutMilliseconds)) {
            return $false
        }

        $stream = $tcpClient.GetStream()
        # ReadTimeout applies per-read, not per-byte; setting it after
        # connect rather than before is required because the stream
        # object does not exist until then.
        $stream.ReadTimeout = $TimeoutMilliseconds

        $buffer = [byte[]]::new(16)
        $read   = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -lt 4) {
            return $false
        }

        # ASCII compare against the protocol-version prefix.
        $prefix = [System.Text.Encoding]::ASCII.GetString($buffer, 0, 4)
        return $prefix -eq 'SSH-'
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $tcpClient) { $tcpClient.Dispose() }
    }
}
