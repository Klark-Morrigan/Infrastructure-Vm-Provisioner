<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1 after
    Infrastructure.HyperV + Posh-SSH are imported (the SSH.NET types this
    helper references are bundled with Posh-SSH).
#>

# ---------------------------------------------------------------------------
# New-VmSshTunnel
#   Opens an SSH session to a jump host and configures a local TCP port
#   forward so traffic to 127.0.0.1:<assigned-port> emerges at
#   <TargetIp>:<TargetPort> on the far side of the jump. This is how the
#   provisioner reaches workload VMs after feature 53 moved them onto a
#   per-environment private switch the host has no route to.
#
#   Why a local port forward (not native ProxyJump):
#     - SSH.NET (the library every other SSH cmdlet in this stack is
#       built on) has no native ProxyJump (`-J`) support. Local port
#       forwarding is the closest equivalent SSH.NET ships out of the
#       box: it gives a localhost endpoint that any TCP-aware caller
#       (Test-VmSshPort, a fresh SshClient connect, etc.) can use
#       without knowing about the jump.
#     - Reusing a single jump session for the whole VM lifecycle (one
#       wait-for-SSH probe loop + one post-provisioning session) saves
#       the cost of re-handshaking the jump on every probe iteration.
#
#   The returned object exposes:
#     - LocalHost / LocalPort : the loopback endpoint callers connect to.
#     - JumpClient / Forward  : the underlying SSH.NET objects, kept for
#                               disposal and so callers that need to
#                               run commands on the jump itself can do
#                               so without re-opening a session.
#     - Dispose()             : tears down the forward and the jump
#                               session in the right order. ALWAYS call
#                               it in a finally block.
# ---------------------------------------------------------------------------

function New-VmSshTunnel {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', 'JumpPassword')]
    [CmdletBinding()]
    param(
        # IPv4 of the VM behind the jump (the workload VM).
        [Parameter(Mandatory)]
        [string] $TargetIp,

        # IPv4 of the jump host (the router VM). Reachable from the
        # provisioning host directly (it is on the same upstream LAN
        # the host's External vSwitch is bridged to).
        [Parameter(Mandatory)]
        [string] $JumpHostIp,

        [Parameter(Mandatory)]
        [string] $JumpUsername,

        # Plain string required by SSH.NET PasswordAuthenticationMethod.
        # Same caller responsibility as New-VmSshClient - never log it.
        [Parameter(Mandatory)]
        [string] $JumpPassword,

        # TCP port on the target. Defaults to 22 (SSH) because that is
        # the only port the provisioner actually proxies today; making
        # it a parameter keeps the helper reusable for a future probe
        # that wants 80 / 443 / arbitrary.
        [Parameter()]
        [uint32] $TargetPort = 22,

        # SSH.NET applies this to both the jump handshake and the
        # underlying TCP read. Default mirrors New-VmSshClient's 30 s.
        [Parameter()]
        [TimeSpan] $JumpConnectTimeout = [TimeSpan]::FromSeconds(30)
    )

    Assert-SshNetLoaded

    # Open the jump session. New-VmSshClient handles the connect +
    # password auth contract uniformly with every other SSH path in
    # this repo so the jump leg behaves identically to a direct
    # session (host key acceptance, KEX algorithm set, timeout
    # semantics).
    $jumpClient = New-VmSshClient `
                      -IpAddress $JumpHostIp `
                      -Username  $JumpUsername `
                      -Password  $JumpPassword `
                      -Timeout   $JumpConnectTimeout

    # Pick an ephemeral local port the kernel knows is free. Binding a
    # TcpListener to port 0 returns the kernel-assigned port; release
    # immediately so SSH.NET can claim it. The window between release
    # and SSH.NET's bind is small; if a collision did happen,
    # forward.Start() throws and the caller can retry. Cheaper than
    # iterating a fixed port range.
    $listener  = [System.Net.Sockets.TcpListener]::new(
        [System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $localPort = $listener.LocalEndpoint.Port
    $listener.Stop()

    # Configure the forward: 127.0.0.1:<localPort> -> <TargetIp>:<TargetPort>
    # via $jumpClient. SSH.NET tunnels every byte in/out of the
    # localhost socket over the jump session's direct-tcpip channel.
    $forward = [Renci.SshNet.ForwardedPortLocal]::new(
        '127.0.0.1', [uint32]$localPort,
        $TargetIp, $TargetPort)

    # AddForwardedPort registers the forward with the jump client so
    # it shares the session's lifecycle; Start() actually opens the
    # local listener. Both must complete before any caller probe.
    try {
        $jumpClient.AddForwardedPort($forward)
        $forward.Start()
    }
    catch {
        # If forward setup fails (port collision, jump session dropped
        # between AddForwardedPort and Start, etc.) dispose the jump
        # session before propagating so we do not leak the SSH
        # connection.
        if ($jumpClient.IsConnected) { $jumpClient.Disconnect() }
        $jumpClient.Dispose()
        throw
    }

    $tunnel = [PSCustomObject]@{
        LocalHost  = '127.0.0.1'
        LocalPort  = $localPort
        JumpClient = $jumpClient
        Forward    = $forward
    }

    # Dispose tears down the forward FIRST (so existing localhost
    # connections drop) then the jump session. Wrapped in try/catch
    # blocks because the constituent objects throw on double-dispose
    # or on a session that already disconnected uncleanly; the
    # outer caller's finally must not be derailed by cleanup noise.
    Add-Member -InputObject $tunnel `
               -MemberType ScriptMethod `
               -Name Dispose `
               -Value {
        try { if ($this.Forward.IsStarted) { $this.Forward.Stop() } } catch {}
        try { $this.JumpClient.RemoveForwardedPort($this.Forward) } catch {}
        try { $this.Forward.Dispose() } catch {}
        try {
            if ($this.JumpClient.IsConnected) { $this.JumpClient.Disconnect() }
        } catch {}
        try { $this.JumpClient.Dispose() } catch {}
    }

    return $tunnel
}
