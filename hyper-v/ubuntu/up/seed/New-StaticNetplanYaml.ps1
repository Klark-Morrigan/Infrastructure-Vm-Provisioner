<#
.SYNOPSIS
    Builds a netplan v2 YAML document for a Hyper-V VM's static NIC.

.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1 alongside the other up/seed/* helpers.
#>

# ---------------------------------------------------------------------------
# New-StaticNetplanYaml
#   Returns the netplan v2 YAML string that configures a single Hyper-V
#   synthetic NIC with a static IPv4 address, default route, and one DNS
#   server.
#
#   The YAML is shared between two consumers:
#     - the cloud-init NoCloud seed's 'network-config' file (legacy path),
#     - a write_files entry inside 'user-data' that lands the same content
#       at /etc/netplan/99-static.yaml on the running VM.
#   Centralising the template here keeps both consumers in lock-step.
#
#   Matching on driver: hv_netvsc (not on a fixed interface name such as
#   eth0 / enp0s*) is intentional - the kernel-assigned NIC name varies
#   across Ubuntu releases and Hyper-V generations, but hv_netvsc is the
#   driver for every Hyper-V synthetic NIC, so this match always hits.
#
#   The top-level `network:` wrapper is required by netplan and accepted
#   by cloud-init's NoCloud network-config parser. An earlier revision
#   emitted the inner block only - it parsed fine when cloud-init
#   re-rendered it into /etc/netplan/50-cloud-init.yaml (cloud-init
#   added the wrapper), but is rejected when written directly into
#   /etc/netplan/*.yaml via write_files. See docs/dev/implementation/
#   40 - static network config/plan.md step 4 follow-up.
# ---------------------------------------------------------------------------
function New-StaticNetplanYaml {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $IpAddress,
        [Parameter(Mandatory)] [string] $SubnetMask,
        [Parameter(Mandatory)] [string] $Gateway,
        [Parameter(Mandatory)] [string] $Dns
    )

    return @"
network:
  version: 2
  ethernets:
    eth0:
      match:
        driver: hv_netvsc
      dhcp4: false
      addresses:
        - $IpAddress/$SubnetMask
      routes:
        - to: default
          via: $Gateway
      nameservers:
        addresses:
          - $Dns
"@
}
