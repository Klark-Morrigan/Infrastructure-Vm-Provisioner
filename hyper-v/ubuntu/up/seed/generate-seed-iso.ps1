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
#                 `network: {config: disabled}` here (and ONLY here)
#                 because cloud-init reads this file in its init stage,
#                 BEFORE the cc_write_files config module runs. Without
#                 it on first boot, cloud-init falls back to default
#                 DHCP on eth0, writes /etc/netplan/50-cloud-init.yaml,
#                 and stalls waiting for a DHCP lease on VmLAN (an
#                 Internal switch + NAT, no DHCP server). By the time
#                 write_files lands the static config and runcmd
#                 applies it, the NIC is wedged and SSH never reaches
#                 the static IP. See plan.md step 4 follow-up.
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
    # package_upgrade is false to keep the first boot fast; operators can
    # run upgrades afterwards.
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
    # write_files lands two files. The disable flag is delivered from
    # TWO places on purpose:
    #   - The seed's network-config (read in cloud-init's init stage)
    #     stops cloud-init managing networking on FIRST boot.
    #   - This /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
    #     ensures the same on SUBSEQUENT boots, when the seed ISO is
    #     gone and cloud-init re-evaluates from on-disk config only.
    #   1. /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg with
    #      `network: {config: disabled}` - persistent disable flag.
    #   2. /etc/netplan/99-static.yaml - the static config netplan
    #      owns. The 99- prefix outranks the legacy 50-cloud-init.yaml
    #      so behaviour stays deterministic during the transition.
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

packages:
  - openssh-server

package_update: true
package_upgrade: false

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

    # ------------------------------------------------------------------
    # network-config (NoCloud v1+ slot)
    # Disables cloud-init's network management from first boot. The same
    # flag is also placed under /etc/cloud/cloud.cfg.d/ via write_files
    # so subsequent boots (after the seed ISO is gone) stay disabled.
    # See the file header for the first-boot ordering rationale.
    # ------------------------------------------------------------------
    $networkConfig = 'network: {config: disabled}'

    $seedIsoPath = Join-Path $Vm.vmConfigPath "$($Vm.vmName)-seed.iso"
    Write-Host "  Writing: $seedIsoPath"

    New-SeedIso -OutputPath $seedIsoPath -Files @{
        'meta-data'      = $metaData
        'user-data'      = $userData
        'network-config' = $networkConfig
    }

    Write-Host "  [OK] Seed ISO ready: $seedIsoPath" -ForegroundColor Green

    # Store the ISO path on the VM object so Invoke-VmCreation can
    # attach and clean it up without recomputing the path.
    Add-Member -InputObject $Vm -MemberType NoteProperty `
               -Name '_seedIsoPath' -Value $seedIsoPath -Force
}
