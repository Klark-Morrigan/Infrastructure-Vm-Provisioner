<#
.SYNOPSIS
    Builds a netplan v2 YAML document (or just one ethernet entry) for a
    Hyper-V VM's static NIC.

.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1 alongside the other up/seed/* helpers.
#>

# ---------------------------------------------------------------------------
# New-StaticNetplanYaml
#   Returns netplan v2 YAML configuring a single Hyper-V synthetic NIC with
#   a static IPv4 address, optional default route, and optional DNS server.
#
#   Two output shapes:
#     - Default: a complete document wrapped in
#         `network: / version: 2 / ethernets: / <Key>: / ...`.
#         Workload VMs ship this directly to cloud-init's network-config
#         slot and to /etc/netplan/99-static.yaml.
#     - `-NoWrapper`: just the ethernet entry starting at `    <Key>:`,
#         no top-level wrapper. The router seed (feature 53) calls this
#         twice (one per NIC) and wraps the concatenated entries once
#         so both NICs live in a single netplan document.
#
#   Match block:
#     - When `-MacAddress` is supplied, the entry matches by MAC. Used by
#       router VMs which have two synthetic NICs (both `hv_netvsc` driver),
#       so the driver-only match would be ambiguous.
#     - Otherwise the entry matches by driver (`hv_netvsc`). Workload VMs
#       have one synthetic NIC so this is unambiguous and portable across
#       kernel-assigned interface names (eth0 / enp0s*) that differ across
#       Ubuntu releases and Hyper-V generations.
#
#   `-SetName` (optional) emits `set-name: <SetName>` so the kernel-visible
#   NIC name is pinned. Router VMs use this so nftables and dnsmasq can
#   reference `ext0` / `priv0` without guessing.
#
#   `-Gateway` and `-Dns` are optional: a router VM's private-side NIC has
#   no upstream gateway and no DNS server (it IS the gateway and the
#   resolver for downstream VMs), so its entry skips those blocks. The
#   workload caller continues to pass both so its existing behaviour is
#   byte-for-byte preserved.
#
#   `-Optional` emits `optional: true`, which netplan translates to
#   RequiredForOnline=no in the generated networkd unit. The router's
#   private NIC (priv0) has no upstream peer at first boot, so without this
#   `systemd-networkd-wait-online` blocks on it up to its 120s timeout;
#   because cloud-init's network stage is ordered After that unit (and the
#   patched sshd After cloud-config -> cloud-init), the stall pushes back
#   the host's wait-for-SSH probe. Marking priv0 optional lets boot proceed
#   once ext0 (kept required) is up. Workload VMs never pass it - their one
#   NIC must be online for the VM to be useful at all.
# ---------------------------------------------------------------------------
function New-StaticNetplanYaml {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $IpAddress,
        [Parameter(Mandatory)] [string] $SubnetMask,
        [Parameter()]          [string] $Gateway,
        [Parameter()]          [string] $Dns,
        [Parameter()]          [string] $Key = 'eth0',
        [Parameter()]          [string] $MacAddress,
        [Parameter()]          [string] $SetName,
        [Parameter()]          [switch] $Optional,
        [Parameter()]          [switch] $NoWrapper
    )

    # Build the ethernet entry line-by-line so optional blocks (set-name,
    # routes, nameservers) can be skipped without leaving stray blank
    # lines that netplan would silently parse as empty mappings.
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("    ${Key}:")
    $lines.Add('      match:')
    if ($MacAddress) {
        $lines.Add("        macaddress: $MacAddress")
    }
    else {
        $lines.Add('        driver: hv_netvsc')
    }
    if ($SetName) {
        $lines.Add("      set-name: $SetName")
    }
    # optional: true => RequiredForOnline=no, so systemd-networkd-wait-online
    # does not gate boot on this link (see header for the sshd-probe chain).
    if ($Optional) {
        $lines.Add('      optional: true')
    }
    $lines.Add('      dhcp4: false')
    $lines.Add('      addresses:')
    $lines.Add("        - $IpAddress/$SubnetMask")
    if ($Gateway) {
        $lines.Add('      routes:')
        $lines.Add('        - to: default')
        $lines.Add("          via: $Gateway")
    }
    if ($Dns) {
        $lines.Add('      nameservers:')
        $lines.Add('        addresses:')
        $lines.Add("          - $Dns")
    }
    $entry = $lines -join "`n"

    if ($NoWrapper) {
        return $entry
    }

    return @"
network:
  version: 2
  ethernets:
$entry
"@
}
