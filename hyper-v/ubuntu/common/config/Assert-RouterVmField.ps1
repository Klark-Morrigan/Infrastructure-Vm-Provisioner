<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    ConvertFrom-VmConfigJson.ps1.
#>

# ---------------------------------------------------------------------------
# Assert-RouterVmField
#   Validates the router-specific portion of a VM definition. Router VMs
#   need extra downstream-NIC fields, cannot carry toolchain blocks, and
#   have a kind-specific addressing-mode choice for the upstream NIC.
#   This validator pins all of that in one place so the schema dispatch
#   in ConvertFrom-VmConfigJson is just a kind-check + a call here.
#
#   Always required (in addition to the base required-field set, which
#   ConvertFrom-VmConfigJson enforces - 'privateSwitchName' lives there
#   because workload VMs also need it):
#     - externalSwitchName  : Hyper-V switch the router's upstream NIC
#                             attaches to. Created on demand by
#                             Ensure-ExternalSwitch when absent; reused
#                             when present.
#     - externalAdapterName : Physical NIC the External switch binds to
#                             when Ensure-ExternalSwitch needs to create
#                             it. Required at schema time because the
#                             config layer cannot tell whether the
#                             switch already exists; if it does, the
#                             field is ignored at runtime.
#     - privateIpAddress    : IP the router carries on its private-side
#                             NIC. Downstream VMs use it as their
#                             default gateway and DNS server. Always
#                             static - no DHCP path can pre-commit a
#                             value workloads can be configured against.
#
#   Optional:
#     - externalDhcp        : addressing mode for the upstream (ext0)
#                             NIC. Defaults to $true (DHCP). Set $false
#                             to pin a static address - typically for
#                             a fixed-workstation deployment whose LAN
#                             never changes. When $false,
#                             ipAddress/subnetMask/gateway from the base
#                             schema become REQUIRED here; when $true,
#                             they are ignored if present (DHCP supplies
#                             everything ext0 needs).
#
#                             Default of $true exists because the host's
#                             External vSwitch is often Wi-Fi-bridged
#                             on a mobile workstation, and a static IP
#                             on the wrong LAN leaves the router with
#                             no upstream connectivity. DHCP picks up
#                             whichever LAN is currently bridged and
#                             "just works" across networks.
#
#   Rejected:
#     - javaDevKit, dotnetSdk, dotnetTools - a router VM is intentionally
#       minimal (nftables + dnsmasq only). Surfacing the rejection at
#       schema-time keeps a stray toolchain entry from silently flowing
#       through reconcile and installing a JDK on the gateway.
# ---------------------------------------------------------------------------

function Assert-RouterVmField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Vm
    )

    $vmName = if ($Vm.PSObject.Properties['vmName']) { $Vm.vmName } else { '(unknown)' }
    $ctx    = "VM '$vmName' (kind 'router')"

    foreach ($field in @('externalSwitchName', 'externalAdapterName', 'privateIpAddress')) {
        if (-not $Vm.PSObject.Properties[$field]) {
            throw "${ctx} is missing required field '$field'."
        }
        $value = $Vm.$field
        if ($null -eq $value -or
            ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
            throw "${ctx}.$field must be a non-empty string."
        }
    }

    # externalDhcp defaults to $true. The default is captured in
    # provision-time code (Invoke-RouterSeedIsoGeneration consults the
    # field) so we don't mutate $Vm here - keeps the validator pure
    # (no side effects on its input) and the default decision in one
    # place. Tests pass $Vm in both shapes (field present or absent).
    $externalDhcp = if ($Vm.PSObject.Properties['externalDhcp']) {
        # Booleans round-trip from JSON as System.Boolean already; the
        # type cast is defensive against operators writing "true" /
        # "false" as strings (still parses).
        [bool] $Vm.externalDhcp
    } else { $true }

    if (-not $externalDhcp) {
        # Static-mode requires the two ext0-specific fields workloads
        # always use. subnetMask is universal (it lives in the base
        # required-field set; the router uses it for priv0 even under
        # DHCP) so it is not gated here.
        foreach ($field in @('ipAddress', 'gateway')) {
            if (-not $Vm.PSObject.Properties[$field]) {
                throw (
                    "${ctx} has externalDhcp=false but is missing required " +
                    "static-address field '$field'."
                )
            }
            $value = $Vm.$field
            if ($null -eq $value -or
                ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
                throw "${ctx}.$field must be a non-empty string."
            }
        }
    }

    foreach ($field in @('javaDevKit', 'dotnetSdk', 'dotnetTools')) {
        if ($Vm.PSObject.Properties[$field]) {
            throw (
                "${ctx} cannot declare '$field'. Router VMs are " +
                "intentionally minimal - install nftables and dnsmasq only."
            )
        }
    }
}
