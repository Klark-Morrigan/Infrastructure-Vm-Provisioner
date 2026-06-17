<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    ConvertFrom-VmConfigJson.ps1.
#>

# ---------------------------------------------------------------------------
# Assert-WorkloadVmField
#   Validates the workload-specific portion of a VM definition. A
#   workload VM must carry a static IP / subnetMask / gateway because
#   its gateway equals the router VM's privateIpAddress - a config-time
#   choice no DHCP path can substitute for.
#
#   The fields used to live in ConvertFrom-VmConfigJson's base required-
#   field list, but moved here when router VMs started supporting DHCP
#   on their upstream NIC (the host's External vSwitch can be bridged
#   to a Wi-Fi adapter whose subnet changes per location, so the static
#   pin there kept breaking provisioning across networks).
#
#   Required (in addition to the base required-field set, which is
#   already enforced by ConvertFrom-VmConfigJson - that set covers
#   subnetMask among others):
#     - ipAddress  : workload VM's IP on the per-environment private
#                    switch. Must sit on the same /24 the router VM's
#                    privateIpAddress is on.
#     - gateway    : equals the router VM's privateIpAddress.
#                    Assert-EnvironmentConsistency enforces the equality.
# ---------------------------------------------------------------------------

function Assert-WorkloadVmField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Vm
    )

    $vmName = if ($Vm.PSObject.Properties['vmName']) { $Vm.vmName } else { '(unknown)' }
    $ctx    = "VM '$vmName' (kind 'workload')"

    foreach ($field in @('ipAddress', 'gateway')) {
        if (-not $Vm.PSObject.Properties[$field]) {
            throw "${ctx} is missing required field '$field'."
        }
        $value = $Vm.$field
        if ($null -eq $value -or
            ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
            throw "${ctx}.$field must be a non-empty string."
        }
    }
}
