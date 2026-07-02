<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1 alongside the other up/seed/* helpers.
#>

# ---------------------------------------------------------------------------
# New-CloudInitDisableNetworkConfigEntry
#   Returns the write_files entry that lands
#   /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg on the VM. The
#   file is read by cloud-init on every SUBSEQUENT boot and instructs it
#   to leave /etc/netplan/*.yaml alone, so netplan - not cloud-init - is
#   the on-disk owner of the static config from first boot onwards.
#
#   First boot is not its concern: cloud-init's own network-config slot
#   drives that, and the seed-bundled write_files /etc/netplan/*.yaml is
#   already on disk by the time runcmd fires. The disable flag closes the
#   loop on every boot AFTER the first, where a stray cloud-init network
#   re-evaluation would otherwise overwrite the static config and force
#   the VM back onto DHCP.
#
#   Shared by the workload and router seed generators so the path /
#   permissions / payload are owned in one place.
# ---------------------------------------------------------------------------
function New-CloudInitDisableNetworkConfigEntry {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return @"
  - path: /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
    permissions: '0644'
    content: 'network: {config: disabled}'
"@
}
