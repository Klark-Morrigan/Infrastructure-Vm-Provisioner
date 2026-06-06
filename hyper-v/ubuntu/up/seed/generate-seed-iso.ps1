<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1 after iso.ps1 is loaded (New-SeedIso must be available)
    and after the shared seed helpers (Initialize-SeedConfigDirectory,
    New-CloudInitMetaData, New-CloudInitUserBlock,
    New-CloudInitDisableNetworkConfigEntry, Format-CloudInitLiteralBlock,
    Write-VmSeedIso) have been dot-sourced.
#>

# ---------------------------------------------------------------------------
# Invoke-SeedIsoGeneration
#   Builds the three cloud-init files and writes a NoCloud seed ISO for a
#   single workload VM. The ISO is placed in Vm.vmConfigPath.
#
#   cloud-init's NoCloud datasource reads from a filesystem volume labelled
#   'cidata'. Three files are placed in the root of the ISO:
#
#     meta-data        - instance identity (instance-id, local-hostname).
#                        See New-CloudInitMetaData.
#     user-data        - cloud-config: OS user, SSH, write_files entries
#                        that drop the static netplan and the cloud-init
#                        network-disable flag, plus a runcmd that applies
#                        the netplan during first boot.
#     network-config   - the NoCloud "network config v1+" slot. Ships the
#                        FULL static netplan so cloud-init's init-local
#                        stage brings the NIC up on first boot with the
#                        configured static IP. Without this slot
#                        cloud-init would fall back to DHCP, briefly
#                        leaving the VM on a wrong IP before runcmd's
#                        `netplan apply` takes over.
#
#   On subsequent boots /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
#   tells cloud-init to leave /etc/netplan/*.yaml alone, so netplan - not
#   cloud-init - owns the on-disk file for the life of the VM.
#
#   SECURITY - user-data contains Vm.password in plaintext so cloud-init
#   can hash it internally (plain_text_passwd). The ISO persists on the
#   host after provisioning; Invoke-VmCreation removes it from disk as
#   soon as SSH is reachable. Restrict read access to Vm.vmConfigPath to
#   the provisioning account.
# ---------------------------------------------------------------------------
function Invoke-SeedIsoGeneration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Vm
    )

    Write-Host ""
    Write-Host "--- Cloud-init ISO: $($Vm.vmName) ---" -ForegroundColor Cyan

    Initialize-SeedConfigDirectory -Path $Vm.vmConfigPath

    $metaData = New-CloudInitMetaData -VmName $Vm.vmName

    # Static netplan YAML used by both the network-config slot (first
    # boot) and the user-data write_files entry (on-disk owner from
    # first boot onwards). Centralised in New-StaticNetplanYaml so the
    # two sources cannot drift.
    $netplanYaml = New-StaticNetplanYaml `
        -IpAddress  $Vm.ipAddress `
        -SubnetMask $Vm.subnetMask `
        -Gateway    $Vm.gateway `
        -Dns        $Vm.dns

    $netplanIndented = Format-CloudInitLiteralBlock -Body $netplanYaml

    # No packages / package_update / package_upgrade: openssh-server is
    # already installed and enabled in the Ubuntu cloud image (see
    # Invoke-BaseImagePatch.ps1 Patch 2), and we install no other
    # packages during cloud-init. Emitting `package_update: true` would
    # run `apt-get update` against Ubuntu mirrors - if the host's NAT
    # does not cover the VM subnet (common: only one NetNat is allowed
    # per host so a production NAT for a different subnet wins), DNS
    # resolution fails and apt waits its full retry budget per source
    # (~90s x 4 sources ~= 6 minutes) before giving up and falling back
    # to cached lists. Omitting these keys lets cloud-init's
    # package_update_upgrade_install module short-circuit to a no-op.
    $userBlock        = New-CloudInitUserBlock -Username $Vm.username -Password $Vm.password
    $disableEntry     = New-CloudInitDisableNetworkConfigEntry

    $userData = @"
#cloud-config

$userBlock

write_files:
$disableEntry
  - path: /etc/netplan/99-static.yaml
    permissions: '0600'
    content: |
$netplanIndented

runcmd:
  - netplan apply
"@

    # network-config (NoCloud v1+ slot) carries the same netplan so
    # first-boot bring-up and on-disk owner cannot drift.
    Write-VmSeedIso -Vm $Vm `
                    -MetaData      $metaData `
                    -UserData      $userData `
                    -NetworkConfig $netplanYaml
}
