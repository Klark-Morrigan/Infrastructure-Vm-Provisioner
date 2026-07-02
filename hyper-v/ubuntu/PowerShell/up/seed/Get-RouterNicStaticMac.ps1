<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1 alongside the other up/seed/* helpers.
#>

# ---------------------------------------------------------------------------
# Get-RouterNicStaticMac
#   Derives a deterministic, locally-administered MAC address for one of a
#   router VM's two NICs. Two formats are returned because both consumers
#   need a different shape:
#
#     - HyperV  : 12 lowercase hex chars, no separators. The format
#                 Set-VMNetworkAdapter / Add-VMNetworkAdapter -StaticMacAddress
#                 accept. Pinned at VM-creation time so the MAC the seed
#                 already embedded is the MAC Hyper-V hands to the guest.
#     - Netplan : six lowercase hex octets joined by ':'. The format
#                 netplan v2 expects in `match.macaddress`. Embedded in
#                 the router's cloud-init seed so cloud-init's init-local
#                 stage can pin per-NIC config to a specific hardware
#                 address (not to a kernel-assigned name like eth0,
#                 which is not stable across boots once two NICs of the
#                 same driver are present).
#
#   Why deterministic, not Hyper-V's dynamic pool:
#     - The seed ISO is built BEFORE the VM exists in the current
#       pipeline order. The router netplan must already know the MACs
#       at seed-generation time. Letting Hyper-V auto-assign would
#       require either a pipeline reordering (build seed after create)
#       or a "discover-MAC-then-rewrite-seed" round-trip - both more
#       moving parts than a hash-derived MAC.
#
#   Why locally-administered (02:...):
#     - The 02:xx:xx:xx:xx:xx prefix is the IEEE locally-administered
#       unicast range, intentionally carved out to avoid colliding with
#       any assigned OUI. We avoid Microsoft's 00:15:5D Hyper-V dynamic
#       range because Hyper-V draws from it on its own and a hash
#       collision into that pool would be a hard bug to spot.
#
#   Determinism guarantee:
#     - SHA-256 of "<VmName>/<Role>" is taken, the first four bytes are
#       used as the per-VM payload, and the final byte distinguishes
#       'external' (0x00) from 'private' (0x01). The same VmName + Role
#       therefore always yields the same MAC, which is what lets the
#       seed (built first) and the VM (created second) agree without
#       any extra IPC.
# ---------------------------------------------------------------------------

function Get-RouterNicStaticMac {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $VmName,

        [Parameter(Mandatory)]
        [ValidateSet('external', 'private')]
        [string] $Role
    )

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes("$VmName/$Role"))
    }
    finally {
        $sha256.Dispose()
    }

    $roleByte = if ($Role -eq 'external') { 0x00 } else { 0x01 }
    # 0x02 first byte: locally-administered, unicast (the IEEE-reserved
    # prefix for site-managed MACs). The four hash bytes carry the per-VM
    # entropy; the role byte distinguishes the two NICs on the same VM.
    $bytes = @([byte]0x02) +
             @($hash[0], $hash[1], $hash[2], $hash[3]) +
             @([byte] $roleByte)

    $hex     = ($bytes | ForEach-Object { $_.ToString('x2') })
    $hyperV  = -join $hex
    $netplan = $hex -join ':'

    return @{
        HyperV  = $hyperV
        Netplan = $netplan
    }
}
