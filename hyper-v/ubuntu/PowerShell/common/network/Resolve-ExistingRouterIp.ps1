<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1.
#>

# ---------------------------------------------------------------------------
# Resolve-ExistingRouterIp
#   Discovers the upstream IP of an EXISTING router VM via Hyper-V KVP and
#   stamps it back onto the VM def's ipAddress property. A no-op for
#   new-state routers (whose IP create-vm.ps1's wait-for-SSH discovers as
#   part of its own boot sequence) and for routers whose ipAddress is
#   already populated (static-mode operators, or a re-call after the first
#   discovery succeeded).
#
#   Why provision.ps1 needs this in step 7 (network setup):
#     When the router is _state == 'new', create-vm.ps1 runs first for
#     the router, KVP-discovers its IP, and writes it back onto the
#     shared VM def object. The workload's $_RouterVm reference (stamped
#     immediately below) sees the populated value when its own
#     wait-for-SSH iterates.
#
#     When the router is _state == 'existing' (the case that surfaces on
#     every phase after the first, where the router persists across
#     provision runs), create-vm.ps1 is skipped for it. Without this
#     helper, the workload would then read $_RouterVm.ipAddress before
#     anyone populated it and the property access would throw under
#     strict mode.
#
#   KVP needs the VM running. An existing-but-Off router is an operator
#   error (the workload could not reach its jump anyway); Get-VmKvpIpAddress
#   surfaces a directed "VM is not Running" message in that case.
# ---------------------------------------------------------------------------
function Resolve-ExistingRouterIp {
    [CmdletBinding()]
    param(
        # Router VM definition from VmProvisionerConfig, after
        # Select-VmsForProvisioning has stamped its _state. Must
        # carry vmName, externalSwitchName; ipAddress and _state are
        # consulted for the skip checks.
        [Parameter(Mandatory)]
        [object] $RouterVm
    )

    $isExisting    = $RouterVm.PSObject.Properties['_state'] -and
                     $RouterVm._state -eq 'existing'
    $alreadyHasIp  = $RouterVm.PSObject.Properties['ipAddress'] -and
                     $RouterVm.ipAddress
    if (-not $isExisting -or $alreadyHasIp) { return }

    Write-Host "  Resolving existing router '$($RouterVm.vmName)' upstream IP via KVP ..." `
        -NoNewline -ForegroundColor Cyan
    $discoveredIp = Get-VmKvpIpAddress `
                        -VmName     $RouterVm.vmName `
                        -SwitchName $RouterVm.externalSwitchName `
                        -OnPoll     { Write-Host '.' -NoNewline -ForegroundColor Cyan }
    Add-Member -InputObject $RouterVm -MemberType NoteProperty `
               -Name 'ipAddress' -Value $discoveredIp -Force
    Write-Host " $discoveredIp" -ForegroundColor Green
}
