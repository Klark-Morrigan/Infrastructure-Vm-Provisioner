<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    Select-VmsForProvisioning.ps1.
#>

# ---------------------------------------------------------------------------
# Assert-EnvironmentConsistency
#   Per-environment preflight that runs at the top of
#   Select-VmsForProvisioning. An 'environment' is the set of VMs sharing
#   a 'privateSwitchName' value - both the router VM carrying the gateway
#   IP on its private NIC and the workload VMs pointing at that gateway.
#   Feature 53 step 2.
#
#   Invariants (per environment):
#     - All workload VMs share the same 'gateway' and 'subnetMask'. A
#       single private switch is one L2 broadcast domain; mixing
#       subnets on it would give some VMs an unreachable default
#       route. The router VM's top-level 'gateway' is intentionally
#       NOT compared - it describes the router's UPSTREAM (external)
#       NIC and is on a different subnet than the workloads' gateway
#       (which equals the router's downstream privateIpAddress).
#     - Each environment with at least one workload VM has exactly one
#       router VM whose 'privateIpAddress' equals the workloads'
#       'gateway'. Workloads route their egress through that router VM,
#       so a mismatched or missing router VM is a config error - the
#       workloads would silently lose internet access at runtime.
#     - The router's 'subnetMask' must equal the workloads' 'subnetMask'.
#       The schema reuses the single 'subnetMask' field for both of the
#       router's NICs, so the router's downstream NIC sits on the same
#       private subnet as the workloads only when this match holds.
#     - A router-only environment (no workloads in the batch) is
#       allowed: useful for bootstrapping the router before any
#       workloads are added.
#
#   Throws on the first violation with a message identifying the offending
#   VM and the conflicting values. Returns nothing on success.
#
#   Grouping is delegated to Group-VmsByEnvironment so this validator owns
#   only the rules; the bookkeeping has one source of truth shared with
#   provision step 7 and deprovision's per-env teardown.
# ---------------------------------------------------------------------------
function Assert-EnvironmentConsistency {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $VmDefs
    )

    $envGroups = @(Group-VmsByEnvironment -VmDefs $VmDefs)

    foreach ($env in $envGroups) {
        $envName = $env.Name

        # Workload-VM shared gateway and subnetMask. The router VM is
        # not part of this comparison because its top-level 'gateway'
        # is the upstream LAN gateway and is by design on a different
        # subnet than the workloads' gateway (= router's
        # privateIpAddress on the private subnet).
        if ($env.WorkloadVms.Count -gt 0) {
            $firstWorkload = $env.WorkloadVms[0]
            foreach ($vm in $env.WorkloadVms) {
                if ($vm.gateway -ne $firstWorkload.gateway -or
                    $vm.subnetMask -ne $firstWorkload.subnetMask) {
                    throw (
                        "Environment '$envName': workload VMs must share " +
                        "gateway and subnetMask (one private switch = one " +
                        "subnet). Conflict: '$($firstWorkload.vmName)' " +
                        "($($firstWorkload.gateway)/$($firstWorkload.subnetMask)) vs " +
                        "'$($vm.vmName)' ($($vm.gateway)/$($vm.subnetMask))."
                    )
                }
            }
        }

        # Router VM rule fires only when workloads are present. A
        # router-only batch is permitted (bootstrap path).
        if ($env.WorkloadVms.Count -eq 0) { continue }

        $firstWorkload = $env.WorkloadVms[0]

        if ($env.RouterVms.Count -eq 0) {
            throw (
                "Environment '$envName' has $($env.WorkloadVms.Count) " +
                "workload VM(s) but no router VM. Add a router VM with " +
                "privateSwitchName='$envName' and " +
                "privateIpAddress='$($firstWorkload.gateway)' to the config."
            )
        }

        if ($env.RouterVms.Count -gt 1) {
            $names = ($env.RouterVms | ForEach-Object { "'$($_.vmName)'" }) -join ', '
            throw (
                "Environment '$envName' has $($env.RouterVms.Count) " +
                "router VMs ($names) - exactly one is required so " +
                "workloads have a single default gateway."
            )
        }

        $routerVm = $env.RouterVms[0]
        if ($routerVm.privateIpAddress -ne $firstWorkload.gateway) {
            throw (
                "Environment '$envName': router VM " +
                "'$($routerVm.vmName)' has privateIpAddress " +
                "'$($routerVm.privateIpAddress)' but workloads point at " +
                "gateway '$($firstWorkload.gateway)'. Align the two so " +
                "workload traffic routes through the router."
            )
        }

        # Router's subnetMask describes both its NICs (single field in
        # the schema). The downstream NIC sits on the workloads' private
        # subnet, so the masks must match - otherwise the router's
        # downstream IP would be unreachable from the workloads.
        if ($routerVm.subnetMask -ne $firstWorkload.subnetMask) {
            throw (
                "Environment '$envName': router VM " +
                "'$($routerVm.vmName)' has subnetMask " +
                "'$($routerVm.subnetMask)' but workloads use " +
                "'$($firstWorkload.subnetMask)'. The router's downstream " +
                "NIC sits on the workloads' private subnet; the masks " +
                "must match."
            )
        }
    }
}
