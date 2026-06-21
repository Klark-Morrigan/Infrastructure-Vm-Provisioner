<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1.
#>

# ---------------------------------------------------------------------------
# Assert-RouterReady
#   White-box verification of a router VM's load-bearing internal state over
#   the already-open post-provisioning SSH session. Called once per router
#   VM, right after cloud-init wait + diagnostics so a regression in the
#   router-seed payload surfaces in the per-VM provisioning timer report -
#   with a named cause - instead of masking as a confusing curl/dig failure
#   on every downstream workload.
#
#   Checks, in order (throws on the first failure):
#     1. IPv4 forwarding (net.ipv4.ip_forward = 1) - the kernel is in
#        router mode, not host mode.
#     2. Required services active (nftables, dnsmasq) - on failure the
#        `systemctl status` tail is included so the operator does not have
#        to SSH in. Motivated by the 2026-06 dnsmasq.service=inactive case
#        (its `enable --now` raced networkd binding priv0; the seed now
#        ships a wait-network drop-in, and this check is the belt to it).
#     3. NAT + FORWARD nftables rules - MASQUERADE on ext0 (source-rewrite
#        for egress) and the priv0 -> ext0 accept rule. Either missing
#        breaks egress for every downstream workload.
#     4. priv0 carries the configured private gateway IP - downstream VMs
#        use it as their default gateway and DNS server.
#
#   Asserting the full router contract in production means real
#   provisioning runs catch a broken router at provision time; the E2E
#   suite inherits the coverage by invoking provision.ps1 rather than
#   re-probing the router itself.
# ---------------------------------------------------------------------------

function Assert-RouterReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $VmName,

        # The router's private-side (priv0) IP - the gateway/DNS address
        # downstream VMs route through. Verified to be bound on priv0 so a
        # netplan regression that drops it is caught here.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $PrivateIpAddress,

        # Service unit names to verify active. Defaults to the two the
        # router seed installs and enables; callers can pass a narrower set
        # in tests or an extended one if the seed grows.
        [string[]] $RequiredServices = @('nftables.service', 'dnsmasq.service')
    )

    Write-Host "  [router-check] verifying router state on $VmName ..."

    # 1. IPv4 forwarding. Loaded from /etc/sysctl.d/99-router.conf by
    #    `sysctl --system` during cloud-init runcmd and re-applied on every
    #    subsequent boot. Assert on the printed value (not exit code alone)
    #    so the contract is explicit.
    $fwd = Invoke-SshClientCommand -SshClient $SshClient `
        -Command 'sysctl -n net.ipv4.ip_forward'
    if ($fwd.ExitStatus -ne 0) {
        throw "sysctl on '$VmName' failed (exit $($fwd.ExitStatus)): $($fwd.Error)"
    }
    $fwdValue = ($fwd.Output -join "`n").Trim()
    if ($fwdValue -ne '1') {
        throw "net.ipv4.ip_forward on '$VmName' is '$fwdValue' (expected '1')."
    }
    Write-Host "  [router-check] [OK] net.ipv4.ip_forward = 1" -ForegroundColor Green

    # 2. Required services active. systemctl is-active prints
    #    'active' / 'inactive' / 'failed' / 'activating' / etc. and exits 0
    #    only when active. Assert on the printed value (not ExitStatus
    #    alone) because future systemd versions may report 'reloading' /
    #    'activating' with exit 0.
    foreach ($unit in $RequiredServices) {
        $check = Invoke-SshClientCommand -SshClient $SshClient `
            -Command "systemctl is-active $unit"
        $state = ($check.Output -join "`n").Trim()
        if ($state -eq 'active') {
            Write-Host "  [router-check] [OK] $unit is active" -ForegroundColor Green
            continue
        }

        # Pull systemctl status so the operator sees the WHY (bind error,
        # exit code, recent journal entries) in the throw message itself -
        # no separate SSH probe required.
        $status = Invoke-SshClientCommand -SshClient $SshClient `
            -Command "systemctl status --no-pager $unit 2>&1"
        $statusOut = ($status.Output -join "`n").TrimEnd()

        throw (
            "Router service '$unit' on '$VmName' is '$state' " +
            "(expected 'active'). systemctl status output:`n$statusOut"
        )
    }

    # 3. NAT + FORWARD rules. MASQUERADE rewrites the source IP on egress;
    #    the priv0 -> ext0 accept rule lets the packet leave. Either one
    #    missing breaks egress for every downstream workload.
    $nft = Invoke-SshClientCommand -SshClient $SshClient `
        -Command 'sudo nft list ruleset'
    if ($nft.ExitStatus -ne 0) {
        throw "nft list ruleset on '$VmName' failed (exit $($nft.ExitStatus)): $($nft.Error)"
    }
    # Join first so the -notmatch is a boolean test on the whole ruleset,
    # regardless of whether the transport returns Output as one string or
    # an array of lines.
    $nftText = ($nft.Output -join "`n")
    if ($nftText -notmatch 'oifname\s+"ext0"\s+masquerade') {
        throw "MASQUERADE on ext0 not found on '$VmName'."
    }
    if ($nftText -notmatch 'iifname\s+"priv0"\s+oifname\s+"ext0"\s+accept') {
        throw "FORWARD priv0 -> ext0 accept rule not found on '$VmName'."
    }
    Write-Host "  [router-check] [OK] MASQUERADE + FORWARD rules present" `
        -ForegroundColor Green

    # 4. priv0 carries the configured gateway IP. set-name in the router
    #    seed netplan pins the device name to priv0 regardless of kernel
    #    naming; the IP comes from the router entry's privateIpAddress.
    $priv = Invoke-SshClientCommand -SshClient $SshClient `
        -Command 'ip -4 -o addr show dev priv0'
    if ($priv.ExitStatus -ne 0) {
        throw "ip addr show dev priv0 on '$VmName' failed (exit $($priv.ExitStatus)): $($priv.Error)"
    }
    $privText = ($priv.Output -join "`n")
    $pattern  = '(^|\s)' + [regex]::Escape($PrivateIpAddress) + '/'
    if ($privText -notmatch $pattern) {
        throw "priv0 on '$VmName' does not carry $PrivateIpAddress."
    }
    Write-Host "  [router-check] [OK] priv0 carries $PrivateIpAddress" `
        -ForegroundColor Green

    Write-Host "  [router-check] [OK] router is ready." -ForegroundColor Green
}
