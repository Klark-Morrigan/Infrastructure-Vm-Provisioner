<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    ConvertFrom-VmConfigJson.ps1.
#>

# ---------------------------------------------------------------------------
# Assert-RouterVmField
#   Validates the router-specific portion of a VM definition. A router VM
#   needs three extra fields and cannot carry toolchain blocks; this
#   validator pins both rules in one place so the schema dispatch in
#   ConvertFrom-VmConfigJson is just a kind-check + a call here.
#
#   Required (in addition to the base required-field set, which is
#   already enforced by ConvertFrom-VmConfigJson):
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
#     - privateSwitchName   : Hyper-V Private switch the router's
#                             downstream NIC attaches to. Created on
#                             demand by Ensure-PrivateSwitch.
#     - privateIpAddress    : IP the router carries on its private-side
#                             NIC. Downstream VMs (step 2) use it as
#                             their default gateway and DNS server.
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

    foreach ($field in @('externalSwitchName', 'externalAdapterName', 'privateSwitchName', 'privateIpAddress')) {
        if (-not $Vm.PSObject.Properties[$field]) {
            throw "${ctx} is missing required field '$field'."
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
