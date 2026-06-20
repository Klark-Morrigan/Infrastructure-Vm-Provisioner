<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1, which is responsible for also dot-sourcing
    common/network/Remove-LegacySingletonNat.ps1 so the shared cleanup
    helper is in scope when this function runs.
#>

# ---------------------------------------------------------------------------
# Invoke-NetworkSetup
#   Per-environment idempotent cleanup of the singleton-NAT topology that
#   feature 53 step 2 replaces. Runs once per private switch per batch so
#   a rebuilt host or a re-run against a partially-migrated host converges
#   on the router-VM topology without operator intervention.
#
#   Switch creation and the actual NetNat / vNIC sweep both live elsewhere
#   so the responsibilities are unambiguous:
#     - Switch creation: Initialize-PrivateSwitch / Initialize-ExternalSwitch, called
#       from the router-VM loop in provision.ps1.
#     - Cleanup mechanics: Remove-LegacySingletonNat in
#       common/network/Remove-LegacySingletonNat.ps1, shared with
#       Invoke-NetworkTeardown so both flows operate on identical rules.
#
#   This function is the per-environment dispatcher: it announces the
#   scope for the operator-visible log and delegates the work.
#
#   Safe to re-run: the shared helper is presence-based and no-ops when
#   the legacy object is absent.
# ---------------------------------------------------------------------------
function Invoke-NetworkSetup {
    [CmdletBinding()]
    param(
        # The router VM definition that owns the environment. Read for
        # the private switch name (display only) and the gateway IP -
        # the cleanup is meant for THIS environment, not anything else
        # the host happens to host.
        [Parameter(Mandatory)]
        [object] $RouterVm,

        # Workload VMs in the same environment. May be empty (router-
        # only batch). Carried through the signature for symmetry with
        # the rest of the per-env API; the cleanup itself is driven by
        # the router VM's gateway IP, not by any workload field.
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $WorkloadVms
    )

    $envName   = $RouterVm.privateSwitchName
    $gatewayIp = $RouterVm.privateIpAddress

    Write-Host ""
    Write-Host "--- Legacy NAT cleanup: $envName ($gatewayIp) ---" `
        -ForegroundColor Cyan

    Remove-LegacySingletonNat -GatewayIp $gatewayIp
}
