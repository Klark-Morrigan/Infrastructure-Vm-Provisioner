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
#                             Initialize-ExternalSwitch when absent; reused
#                             when present.
#     - externalAdapterName : Physical NIC the External switch binds to
#                             when Initialize-ExternalSwitch needs to create
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
#                             NIC. Defaults to $false (static). When $false
#                             or absent, ipAddress/gateway become REQUIRED
#                             here (subnetMask lives in the base schema);
#                             when $true they are ignored if present (DHCP
#                             supplies everything ext0 needs).
#
#                             The right mode depends on the External
#                             vSwitch topology, and the two cases invert:
#                               - Internal + ICS vSwitch (the default, and
#                                 the only validated host topology): ICS
#                                 always owns 192.168.137.0/24 regardless
#                                 of the upstream Wi-Fi, so a static ext0
#                                 on that subnet is stable across roams -
#                                 and ICS's own DHCP allocator is the flaky
#                                 part (it reassigns the lease, stranding
#                                 the provisioner's cached jump-host IP).
#                                 DHCP-on-ICS is unsupported; the
#                                 production secret pins a static ext0.
#                                 See the README's Networking section.
#                               - Bridged-Wi-Fi/Ethernet External vSwitch:
#                                 ext0 sits directly on the physical LAN,
#                                 whose subnet changes per location. A
#                                 static IP lands on the wrong LAN after a
#                                 move, so this topology opts into DHCP
#                                 (externalDhcp=true) to pick up whichever
#                                 LAN is currently bridged.
#
#                             Default $false makes the working topology the
#                             default; a bridged deployment opts into DHCP
#                             explicitly.
#
#   TODO(dhcp-unfinished): externalDhcp=true (the bridged-External path)
#     is NOT a finished, validated feature. It exists in the schema, the
#     seed (Invoke-RouterSeedIsoGeneration), the create-vm KVP discovery,
#     and Select-VmsForProvisioning, but has never worked end-to-end - the
#     bridged-Wi-Fi External switch it targets never reached its upstream
#     gateway (duplicate-IP via shared MAC; see the README's Networking
#     section), and no E2E scenario
#     exercises it. Only static ext0 on Internal+ICS is supported and
#     tested. Until a bridged deployment is validated end-to-end and
#     covered by E2E, externalDhcp=true is REJECTED outright by the gate
#     below (so it cannot enter the secret JSON or be provisioned). This
#     note is the single source for that status; the DHCP code branches
#     point here rather than repeating it.
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

    # externalDhcp, when supplied, must be a real JSON boolean. This guard
    # inspects the RAW property on purpose - NOT via
    # Test-RouterUsesExternalDhcp, whose [bool] cast would coerce a quoted
    # "false" (or a number) to $true and mask the bad type, the exact
    # footgun we are rejecting. The helper resolves the value just below,
    # once this guard has proven it is a real boolean. Reject a non-boolean
    # here so the malformed config fails fast with a directed message
    # instead of being coerced the wrong way.
    if ($Vm.PSObject.Properties['externalDhcp'] -and
        $Vm.externalDhcp -isnot [bool]) {
        $actual = if ($null -eq $Vm.externalDhcp) {
            'null'
        } else {
            $Vm.externalDhcp.GetType().Name
        }
        throw (
            "${ctx}.externalDhcp must be a JSON boolean (true or false), " +
            "not $actual. If you wrote it as a quoted string, remove the quotes."
        )
    }

    # externalDhcp defaults to $false; Test-RouterUsesExternalDhcp owns
    # that default so the validator, the seed generator, and
    # Select-VmsForProvisioning cannot drift. The type guard above
    # guarantees a real boolean reaches it. We do not mutate $Vm here -
    # the validator stays pure (no side effects on its input).
    $externalDhcp = Test-RouterUsesExternalDhcp -Vm $Vm

    # Hard gate: DHCP mode is unfinished/unsupported (see the
    # dhcp-unfinished TODO above), so reject externalDhcp=true outright at
    # schema time. This validator runs from BOTH setup-secrets.ps1 (before
    # the config is stored in the vault) and provision.ps1 (when it is read
    # back), so a DHCP router cannot enter the secret JSON in the first
    # place, nor be provisioned if one already exists. Lift this gate when
    # the bridged-External path is validated end-to-end and covered by E2E.
    if ($externalDhcp) {
        throw (
            "${ctx} has externalDhcp=true, but DHCP mode is unfinished and " +
            "unsupported - it has never worked end-to-end. Use static " +
            "addressing (omit externalDhcp, or set it false) with ipAddress " +
            "and gateway. See Assert-RouterVmField's externalDhcp note."
        )
    }

    # Only static (the supported mode) reaches here. It requires the two
    # ext0-specific fields workloads always use. subnetMask is universal
    # (it lives in the base required-field set; the router uses it for
    # priv0) so it is not gated here.
    foreach ($field in @('ipAddress', 'gateway')) {
        if (-not $Vm.PSObject.Properties[$field]) {
            throw (
                "${ctx} has externalDhcp=false (static, the default) " +
                "but is missing required static-address field '$field'."
            )
        }
        $value = $Vm.$field
        if ($null -eq $value -or
            ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
            throw "${ctx}.$field must be a non-empty string."
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
