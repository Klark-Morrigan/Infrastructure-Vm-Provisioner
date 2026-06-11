<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1 after iso.ps1, Get-RouterNicStaticMac.ps1, and the
    shared seed helpers (Initialize-SeedConfigDirectory,
    New-CloudInitMetaData, New-CloudInitUserBlock,
    New-CloudInitDisableNetworkConfigEntry, Format-CloudInitLiteralBlock,
    Write-VmSeedIso, New-StaticNetplanYaml) have loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-RouterSeedIsoGeneration
#   Sibling of Invoke-SeedIsoGeneration that builds the cloud-init seed
#   ISO for a router VM (kind: router). The router VM is the dual-NIC
#   gateway introduced in feature 53: one NIC on a host-bridged external
#   switch (upstream), one on a per-environment Hyper-V Private switch
#   (downstream). The seed lands:
#
#     - /etc/netplan/99-router.yaml : netplan v2 with one ethernet entry
#         per NIC, each matched by MAC. set-name pins the kernel
#         interface names to ext0 (upstream) and priv0 (downstream) so
#         the nftables ruleset can hard-code interface names without
#         depending on kernel naming heuristics.
#     - /etc/sysctl.d/99-router.conf  : net.ipv4.ip_forward = 1
#         Switches the kernel from "host" to "router" forwarding mode.
#         Loaded by sysctl --system in runcmd.
#     - /etc/nftables.conf            : MASQUERADE on ext0 (outbound
#         egress) and a FORWARD chain that lets priv0 -> ext0 establish
#         new connections while only allowing ext0 -> priv0 for already-
#         established / related traffic. Loaded by nftables.service.
#     - /etc/dnsmasq.d/router.conf    : dnsmasq bound to the private NIC
#         IP, no-resolv so it doesn't trip over systemd-resolved on the
#         router itself, with the VM's upstream DNS server as the
#         forwarder. Loaded by dnsmasq.service.
#
#   MACs: each NIC needs a stable MAC so netplan's match-by-MAC block
#   can pin per-NIC config. The MAC is derived deterministically here
#   and stashed on the VM object as _externalMac / _privateMac so
#   create-vm.ps1 can pin the same MAC at VM-creation time.
#
#   Netplan composition: New-StaticNetplanYaml is called twice with
#   -NoWrapper (one per NIC), each emitting a wrapper-less ethernet
#   entry. The router code wraps the concatenation once so both NICs
#   live in a single netplan document - a single document is what the
#   network-config slot can ship and what netplan parses as one unit.
#
#   runcmd order (load-bearing):
#     1. Pre-apply diag dump       - print /etc/netplan/ listing, every
#                                     .yaml/.yml file contents, and
#                                     `netplan get` (merged effective)
#                                     to the cloud-init log so the
#                                     serial-console capture has a
#                                     post-mortem record of what
#                                     netplan was asked to apply -
#                                     covers the case where init-local
#                                     wrote 50-cloud-init.yaml but the
#                                     base image shipped a higher-
#                                     priority netplan file that
#                                     shadowed it.
#     2. netplan apply             - bind both NICs so dnsmasq has
#                                     priv0's IP to listen on (step 5).
#                                     Init-local usually applies the
#                                     seed's network-config earlier;
#                                     running netplan apply here is
#                                     the safety net for the cases
#                                     where it does not (e.g. Azure-
#                                     base-image netplan defaults
#                                     shadowing the seed).
#     3. Post-apply diag dump      - `networkctl`, `ip -4 addr`, `ip
#                                     -4 route` so the same log shows
#                                     what landed on the wires - if
#                                     ext0 still has DHCP after apply,
#                                     that names a real netplan-file
#                                     priority issue rather than a
#                                     "netplan apply did not run" one.
#     4. sysctl --system           - turn on forwarding before any
#                                     packet hits the FORWARD chain.
#     5. systemctl enable --now nftables - install the ruleset.
#     6. systemctl enable --now dnsmasq  - bind the resolver to priv0.
#
#   SECURITY mirrors the workload path: user-data carries Vm.password in
#   plaintext for cloud-init's plain_text_passwd, and the seed ISO is
#   removed by Invoke-VmCreation's finally block after first boot.
# ---------------------------------------------------------------------------
function Invoke-RouterSeedIsoGeneration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Vm
    )

    Write-Host ""
    Write-Host "--- Router cloud-init ISO: $($Vm.vmName) ---" -ForegroundColor Cyan

    Initialize-SeedConfigDirectory -Path $Vm.vmConfigPath

    # ------------------------------------------------------------------
    # Deterministic MACs - generated here and stashed on the VM object so
    # create-vm.ps1 can pin the same address. See Get-RouterNicStaticMac
    # for why deterministic-from-vmName rather than letting Hyper-V auto-
    # assign.
    # ------------------------------------------------------------------
    $extMac  = Get-RouterNicStaticMac -VmName $Vm.vmName -Role 'external'
    $privMac = Get-RouterNicStaticMac -VmName $Vm.vmName -Role 'private'

    Add-Member -InputObject $Vm -MemberType NoteProperty `
               -Name '_externalMac' -Value $extMac.HyperV -Force
    Add-Member -InputObject $Vm -MemberType NoteProperty `
               -Name '_privateMac'  -Value $privMac.HyperV -Force

    $metaData = New-CloudInitMetaData -VmName $Vm.vmName

    # ------------------------------------------------------------------
    # Netplan: two ethernet entries in one document. New-StaticNetplanYaml
    # owns the entry shape (match block / dhcp4 / addresses / optional
    # routes and nameservers); the wrapper is composed here so both
    # entries share one `network: / version: 2 / ethernets:` header.
    #
    # The external NIC has two modes:
    #   - externalDhcp $true (the schema default): emit a minimal DHCP
    #     entry. The router picks up whatever LAN the host's External
    #     vSwitch is bridged to, so changing networks (operator moves
    #     between Wi-Fi hotspots / different office VLANs) does not
    #     require re-pinning the seed. The router's own DNS resolution
    #     comes from DHCP; the router VM's `dns` field is used by
    #     dnsmasq's upstream forwarder, not by ext0's resolver.
    #   - externalDhcp $false: full static via New-StaticNetplanYaml,
    #     same shape workload VMs use. The validator requires
    #     ipAddress / subnetMask / gateway in that mode.
    #
    # The private NIC is always static and carries neither gateway nor
    # nameservers - it IS the gateway and resolver for downstream VMs.
    # ------------------------------------------------------------------
    $externalDhcp = if ($Vm.PSObject.Properties['externalDhcp']) {
        [bool] $Vm.externalDhcp
    } else { $true }

    if ($externalDhcp) {
        # Minimal DHCP entry. Same indentation as New-StaticNetplanYaml
        # produces - the wrapper below assumes four-space indent on the
        # interface key line.
        $extEntry = @"
    ext0:
      match:
        macaddress: $($extMac.Netplan)
      set-name: ext0
      dhcp4: true
"@
    }
    else {
        $extEntry = New-StaticNetplanYaml `
            -Key        'ext0' `
            -MacAddress $extMac.Netplan `
            -SetName    'ext0' `
            -IpAddress  $Vm.ipAddress `
            -SubnetMask $Vm.subnetMask `
            -Gateway    $Vm.gateway `
            -Dns        $Vm.dns `
            -NoWrapper
    }

    $privEntry = New-StaticNetplanYaml `
        -Key        'priv0' `
        -MacAddress $privMac.Netplan `
        -SetName    'priv0' `
        -IpAddress  $Vm.privateIpAddress `
        -SubnetMask $Vm.subnetMask `
        -NoWrapper

    $netplanYaml = @"
network:
  version: 2
  ethernets:
$extEntry
$privEntry
"@

    # ------------------------------------------------------------------
    # nftables ruleset. Static interface names (ext0 / priv0) are stable
    # because the netplan above pins them via set-name. Policy on FORWARD
    # is drop so anything that is not in the two explicit accept rules
    # is rejected; policy on INPUT/OUTPUT is accept because the router's
    # own traffic is not the concern of this feature.
    # ------------------------------------------------------------------
    $nftablesConf = @'
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter; policy accept;
    }
    chain forward {
        type filter hook forward priority filter; policy drop;
        iifname "priv0" oifname "ext0" accept
        iifname "ext0" oifname "priv0" ct state established,related accept
    }
    chain output {
        type filter hook output priority filter; policy accept;
    }
}

table ip nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "ext0" masquerade
    }
}
'@

    # ------------------------------------------------------------------
    # dnsmasq config. bind-interfaces restricts the listener to the
    # specified address only (default: bind to wildcard, accept queries
    # on any interface) so a downstream-side resolver can't accidentally
    # serve queries from the upstream side. no-resolv stops dnsmasq from
    # reading /etc/resolv.conf for upstream resolvers - the upstream is
    # whatever the operator configured on the VM (Vm.dns), full stop.
    # ------------------------------------------------------------------
    $dnsmasqConf = @"
no-resolv
interface=priv0
bind-interfaces
listen-address=$($Vm.privateIpAddress)
server=$($Vm.dns)
"@

    # sysctl: forwarding flag. Loaded by sysctl --system in runcmd.
    $sysctlConf = 'net.ipv4.ip_forward = 1'

    # ------------------------------------------------------------------
    # dnsmasq systemd drop-in. Fixes a startup race observed in 2026-06:
    # dnsmasq starts at runcmd time and tries to bind to priv0's static
    # IP (listen-address=10.99.0.1 above), but networkd has not finished
    # applying the netplan yet, so the IP is not bound. dnsmasq's
    # 'failed to create listening socket: Cannot assign requested
    # address' fires, the unit exits 2, systemd marks it inactive
    # (dead), and the E2E assertion phase later reports
    # dnsmasq.service=inactive.
    #
    # Two-line fix:
    #   - After=systemd-networkd-wait-online.service: do not start
    #     until networkd has at least one configured interface ready.
    #     The unit is in the default boot target on Ubuntu cloud
    #     images so we do not need to enable it ourselves.
    #   - Restart=on-failure / RestartSec=5: if the bind still races
    #     (networkd-wait-online completes on ext0 alone before priv0
    #     is up), systemd retries until priv0 is bound. Capped at
    #     the default StartLimit so a true config error still surfaces.
    # ------------------------------------------------------------------
    $dnsmasqDropIn = @'
[Unit]
After=systemd-networkd-wait-online.service
Wants=systemd-networkd-wait-online.service

[Service]
Restart=on-failure
RestartSec=5
'@

    # ------------------------------------------------------------------
    # user-data. The structure mirrors Invoke-SeedIsoGeneration
    # (users, ssh_pwauth, write_files, runcmd). No `packages:` block:
    # cloud-init's `packages:` runs in the init stage BEFORE runcmd's
    # `netplan apply`, which on a static-ext0 router means apt tries
    # to resolve archive.ubuntu.com over an interface with no IPv4
    # yet and times out. The 2026-06 dnsmasq-not-installed regression
    # was this exact race. nftables and dnsmasq are instead
    # installed via apt-get in runcmd AFTER `netplan apply`, with
    # `DEBIAN_FRONTEND=noninteractive` so any post-install prompts
    # do not hang the runcmd.
    #
    # runcmd ordering note: `systemctl daemon-reload` sits BETWEEN the
    # nftables enable and the dnsmasq enable so systemd picks up the
    # dnsmasq.service.d/10-wait-network.conf drop-in (from write_files
    # above) before the first `enable --now` triggers the unit start.
    # Without the reload the drop-in's After=/Wants=/Restart= settings
    # would not be in effect at first start and the bind-race could
    # still leave dnsmasq inactive.
    #
    # DNS path: the operator's Vm.dns is consumed in two places:
    # netplan's nameserver for ext0 (so the router VM itself uses
    # it) and dnsmasq's `server=` upstream (so workloads on priv0
    # use it transitively). For the Internal+ICS topology, the
    # right value is the host's ICS-gateway address (typically
    # 192.168.137.1) - that hop is local on the Internal switch
    # (no NAT) and ICS's built-in DNS proxy on the host forwards
    # to whatever DNS the host's WiFi is configured with. Earlier
    # iterations tried `8.8.8.8` directly; UDP/53 outbound over
    # ICS NAT to public resolvers is unreliable in the cloud-init
    # window (the diag history captured "Temporary failure
    # resolving" against an apt request seconds after `getent`
    # against the SAME host succeeded). Pointing at the ICS proxy
    # sidesteps the NAT entirely - see
    # feedback_router_seed_resolvconf_bypass memory for the deeper
    # write-up of the broken path we abandoned.
    #
    # DNS-ready poll: belt-and-suspenders sanity check that at
    # least one resolver answers before firing apt. `timeout 120`
    # bounds the wait so a genuinely broken DNS path fails
    # predictably instead of hanging.
    # ------------------------------------------------------------------
    $userBlock        = New-CloudInitUserBlock -Username $Vm.username -Password $Vm.password
    $disableEntry     = New-CloudInitDisableNetworkConfigEntry
    $netplanIndented  = Format-CloudInitLiteralBlock -Body $netplanYaml
    $sysctlIndented   = Format-CloudInitLiteralBlock -Body $sysctlConf
    $nftablesIndented      = Format-CloudInitLiteralBlock -Body $nftablesConf
    $dnsmasqIndented       = Format-CloudInitLiteralBlock -Body $dnsmasqConf
    $dnsmasqDropInIndented = Format-CloudInitLiteralBlock -Body $dnsmasqDropIn

    $userData = @"
#cloud-config

$userBlock

write_files:
$disableEntry
  # The Azure cloud image ships /etc/netplan/90-hotplug-azure.yaml with
  # an 'ephemeral' entry that matches every hv_netvsc NIC NOT named
  # eth0 and turns on dhcp4: true on it. After our set-name renames the
  # router's NICs to ext0 / priv0 both match that pattern, fight our
  # static config in 99-router.yaml, and leave networkd stuck on
  # `configuring` while DHCP tries to lease addresses neither
  # interface wants. Overwriting the file with an empty-but-valid
  # netplan document neutralises it without removing the path - the
  # Azure agent (walinuxagent) will not regenerate it because the file
  # still exists.
  - path: /etc/netplan/90-hotplug-azure.yaml
    permissions: '0600'
    content: |
      network:
        version: 2
  - path: /etc/netplan/99-router.yaml
    permissions: '0600'
    content: |
$netplanIndented
  - path: /etc/sysctl.d/99-router.conf
    permissions: '0644'
    content: |
$sysctlIndented
  - path: /etc/nftables.conf
    permissions: '0755'
    content: |
$nftablesIndented
  - path: /etc/dnsmasq.d/router.conf
    permissions: '0644'
    content: |
$dnsmasqIndented
  - path: /etc/systemd/system/dnsmasq.service.d/10-wait-network.conf
    permissions: '0644'
    content: |
$dnsmasqDropInIndented

runcmd:
  - sh -c "echo '--- [diag] /etc/netplan/ ---'; ls -la /etc/netplan/; for f in /etc/netplan/*.yaml /etc/netplan/*.yml; do [ -f \"`$f\" ] || continue; echo \"=== `$f ===\"; cat \"`$f\"; done; echo '--- [diag] netplan get ---'; netplan get 2>&1 || true"
  - netplan apply
  - sh -c "echo '--- [diag] networkctl post-apply ---'; networkctl --no-pager 2>&1 || true; echo '--- [diag] ip -4 addr ---'; ip -4 -o addr; echo '--- [diag] ip -4 route ---'; ip -4 route"
  - sysctl --system
  - timeout 120 sh -c 'until getent hosts archive.ubuntu.com >/dev/null 2>&1; do echo "  [wait-dns] DNS not ready yet, retrying ..."; sleep 2; done'
  - apt-get update
  - DEBIAN_FRONTEND=noninteractive apt-get install -y nftables dnsmasq
  - systemctl enable --now nftables.service
  - systemctl daemon-reload
  - systemctl enable --now dnsmasq.service
"@

    # network-config ships the same netplan so cloud-init's init-local
    # stage brings both NICs up on first boot before the config stage
    # runs apt. Identical content to /etc/netplan/99-router.yaml above.
    Write-VmSeedIso -Vm $Vm `
                    -MetaData      $metaData `
                    -UserData      $userData `
                    -NetworkConfig $netplanYaml
}
