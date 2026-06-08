<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1 alongside
    the other common/network helpers.
#>

# ---------------------------------------------------------------------------
# Resolve-RouterUpstreamHostIp
#   Returns the Windows host's IPv4 address on the same /24 as the supplied
#   router upstream IP. Used by Invoke-VmPostProvisioning to bind the HTTP
#   file server on an adapter the router can reach over its ext0 link, so
#   workloads behind the router's MASQUERADE NAT can curl host-staged
#   artefacts during post-provisioning.
#
#   This duplicates Infrastructure.HyperV's private Get-VmSwitchHostIp on
#   purpose: Get-VmSwitchHostIp is not exported (it has been an internal
#   detail of Start-VmFileServer's -VmIpAddress code path), and promoting
#   it would add a module-version bump + PSGallery publish + every
#   consumer pinning a new minimum version. The logic is six lines of
#   Get-NetIPAddress filtering with no platform dependency beyond what is
#   already loaded for the provisioner, so a local copy is the smaller
#   blast radius. If a second consumer appears, that is the right moment
#   to promote it into the shared module.
# ---------------------------------------------------------------------------
function Resolve-RouterUpstreamHostIp {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # The router VM's discovered ext0 IPv4 address (KVP-discovered
        # under the externalDhcp default; static when externalDhcp is
        # $false). Used as the /24 anchor for the host-side lookup.
        [Parameter(Mandatory)]
        [string] $RouterIpAddress
    )

    # /24 prefix of the router's upstream address. The host's WiFi /
    # Ethernet adapter that bridges into the External vSwitch sits on
    # the same physical LAN, so its IP shares the same first three
    # octets. Anything else on the host (loopback, other Hyper-V
    # switches' adapters, VPN tunnels) is filtered out by the prefix
    # match.
    $parts  = $RouterIpAddress -split '\.'
    $prefix = "$($parts[0]).$($parts[1]).$($parts[2])."

    # Excluding $RouterIpAddress itself is defensive: the host should
    # not have the router's address, but if the same /24 is shared with
    # other Hyper-V environments the filter still picks the host's
    # local entry deterministically.
    $hostIp = Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object {
            $_.IPAddress.StartsWith($prefix) -and
            $_.IPAddress -ne $RouterIpAddress
        } |
        Select-Object -First 1 -ExpandProperty IPAddress

    if (-not $hostIp) {
        throw (
            "No host adapter found on the same /24 as the router upstream " +
            "IP '$RouterIpAddress' (prefix '$prefix'). Check that the " +
            "External vSwitch is bridged to a host adapter that has an " +
            "IPv4 lease on the same LAN as the router."
        )
    }

    $hostIp
}
