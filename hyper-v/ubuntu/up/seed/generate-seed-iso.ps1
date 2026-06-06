<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1 after iso.ps1 is loaded (New-SeedIso must be available).
#>

# ---------------------------------------------------------------------------
# Invoke-SeedIsoGeneration
#   Builds the three cloud-init files and writes a NoCloud seed ISO for a
#   single VM. The ISO is placed in Vm.vmConfigPath.
#
#   cloud-init's NoCloud datasource reads from a filesystem volume labelled
#   'cidata'. Two files are placed in the root of the ISO:
#
#     meta-data - instance identity (instance-id, local-hostname).
#     user-data - cloud-config: OS user, SSH, installed packages, and
#                 write_files entries that drop a static netplan file
#                 owned by netplan from first boot onwards. See
#                 docs/dev/implementation/40 - static network config.
#     network-config - the NoCloud "network config v1+" slot. We ship
#                 the FULL static netplan here so cloud-init's
#                 init-local stage brings the NIC up on first boot
#                 with the configured static IP (writes
#                 /etc/netplan/50-cloud-init.yaml, runs netplan
#                 apply). Without this slot cloud-init would fall
#                 back to DHCP, briefly leaving the VM on a wrong IP
#                 before runcmd's `netplan apply` takes over.
#                 Subsequent-boot regressions are blocked instead
#                 by the persistent disable flag landed via
#                 write_files (see below) and by /etc/netplan/
#                 99-static.yaml outranking the legacy
#                 50-cloud-init.yaml. See docs/dev/implementation/
#                 40 - static network config/plan.md step 4 follow-up.
#
#   SECURITY - user-data contains Vm.password in plaintext so cloud-init
#   can hash it internally (plain_text_passwd). The ISO persists on the
#   host after provisioning; delete it once the VM is running, or restrict
#   read access to Vm.vmConfigPath to the provisioning account only.
#
#   On return, $Vm._seedIsoPath is set via Add-Member for use by
#   Invoke-VmCreation.
# ---------------------------------------------------------------------------
function Invoke-SeedIsoGeneration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Vm
    )

    Write-Host ""
    Write-Host "--- Cloud-init ISO: $($Vm.vmName) ---" -ForegroundColor Cyan

    # Ensure the vmConfigPath directory exists.
    if (-not (Test-Path -Path $Vm.vmConfigPath -PathType Container)) {
        New-Item -ItemType Directory -Path $Vm.vmConfigPath -Force | Out-Null
        Write-Host "  Created directory: $($Vm.vmConfigPath)"
    }

    # ------------------------------------------------------------------
    # meta-data
    # instance-id must change if the instance is re-created from scratch;
    # using vmName satisfies this for our one-VM-per-name model. It also
    # sets the Linux hostname on first boot via local-hostname.
    # ------------------------------------------------------------------
    $metaData = @"
instance-id: $($Vm.vmName)
local-hostname: $($Vm.vmName)
"@

    # ------------------------------------------------------------------
    # user-data (cloud-config)
    #
    # plain_text_passwd lets cloud-init hash the password internally,
    # avoiding the need to pre-compute a sha512crypt hash on Windows.
    # lock_passwd must be false - without it cloud-init locks the account
    # after setting the password, blocking SSH password auth even when
    # ssh_pwauth is true.
    # Specifying users: without 'default' in the list intentionally omits
    # the cloud image's built-in 'ubuntu' user; only our configured user
    # is created.
    # No packages / package_update / package_upgrade: openssh-server is
    # already installed and enabled in the Ubuntu cloud image (see
    # Invoke-BaseImagePatch.ps1 Patch 2), and we install no other
    # packages during cloud-init. Emitting `package_update: true` would
    # run `apt-get update` against Ubuntu mirrors - if the host's NAT
    # does not cover the VM subnet (common: only one NetNat is allowed
    # per host so a production NAT for a different subnet wins), DNS
    # resolution fails and apt waits its full retry budget per source
    # (~90s x 4 sources ~= 6 minutes) before giving up and falling
    # back to cached lists. That wait was the entire cloud-init wait
    # ~365s observed in earlier runs. Omitting these keys lets
    # cloud-init's package_update_upgrade_install module short-circuit
    # to a no-op, and removes the only piece of cloud-init that
    # actually needed outbound internet.
    #
    # Values that may contain YAML-special characters (colon, hash, quote)
    # are wrapped in YAML double-quoted strings. Backslashes and double
    # quotes within those strings are escaped below.
    # ------------------------------------------------------------------
    $yamlUsername = $Vm.username -replace '\\', '\\' -replace '"', '\"'
    # cloud-init requires plain_text_passwd as a literal string in YAML.
    # Vm.password is a plain string from ConvertFrom-Json; converting to
    # SecureString would only require converting back here. Protection
    # relies on vault encryption at rest and the short session lifetime.
    $yamlPassword = $Vm.password -replace '\\', '\\' -replace '"', '\"'

    # ------------------------------------------------------------------
    # Static netplan YAML for the user-data write_files entry - the
    # on-disk file netplan owns from first boot onwards. cloud-init's
    # network module is disabled by the companion write_files entry,
    # so the seed no longer ships a separate network-config file.
    # ------------------------------------------------------------------
    $netplanYaml = New-StaticNetplanYaml `
        -IpAddress  $Vm.ipAddress `
        -SubnetMask $Vm.subnetMask `
        -Gateway    $Vm.gateway `
        -Dns        $Vm.dns

    # ------------------------------------------------------------------
    # Indent the netplan YAML for embedding as a literal block scalar
    # (`content: |`) under a write_files entry. Each line gets six
    # spaces: two for the list item and four for the content key.
    # ------------------------------------------------------------------
    $netplanIndented = ($netplanYaml -split "`r?`n" |
        ForEach-Object { "      $_" }) -join "`n"

    # ------------------------------------------------------------------
    # user-data (cloud-config)
    #
    # write_files lands two files that together close the regression
    # described in problem.md (seed-ISO loss across re-evaluation):
    #   1. /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg with
    #      `network: {config: disabled}` - persistent disable flag
    #      read by cloud-init on every SUBSEQUENT boot. First boot is
    #      not its concern; the seed's network-config drives that.
    #   2. /etc/netplan/99-static.yaml - canonical netplan-owned file.
    #      Redundant on first boot (50-cloud-init.yaml that init-local
    #      writes from network-config has the same content) but it
    #      outranks 50-cloud-init.yaml lexically, so any future leftover
    #      of the latter never wins, and it gives us a stable,
    #      documented path for downstream tooling and assertions.
    # runcmd then applies the new config so the IP is live before
    # cloud-init finishes first boot.
    # ------------------------------------------------------------------
    $userData = @"
#cloud-config

users:
  - name: "$yamlUsername"
    plain_text_passwd: "$yamlPassword"
    lock_passwd: false
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: [adm, cdrom, dip, plugdev, lxd]

ssh_pwauth: true

write_files:
  - path: /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
    permissions: '0644'
    content: 'network: {config: disabled}'
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
