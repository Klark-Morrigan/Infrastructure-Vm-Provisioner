<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1.
#>

# ---------------------------------------------------------------------------
# Initialize-PrivateSwitch
#   Idempotently makes sure a Hyper-V Private switch named <Name> exists on
#   the host. Used by feature 53 (router VM) so a router VM can attach its
#   downstream NIC to a per-environment Private switch without each batch
#   creating a fresh one.
#
#   Why Private (not Internal):
#     - Internal switches expose a host vNIC by design (the host can route
#       and SSH into VMs through it). That side-effect was load-bearing
#       under the old NetNat topology - the host's vNIC IP was the
#       downstream VMs' gateway. With feature 53 the gateway moves to a
#       router VM, so the host vNIC is no longer wanted: it would be a
#       second host-side route into the environment that no traffic
#       should take. Private switches deliberately do not create one.
#
#   What this function does NOT do (moved to the router VM):
#     - Assign a host vNIC IP. The router VM carries the gateway IP on its
#       private-side NIC instead.
#     - Create a NetNat. The router VM MASQUERADEs out its external NIC,
#       so the host's single NetNat slot is freed for whichever
#       environment currently owns it (production).
#
#   Idempotent:
#     - If no switch with that name exists, create it (type Private).
#     - If a Private switch with that name already exists, log and return.
#     - If a switch with that name exists but is type Internal or
#       External, throw - the caller asked for a Private switch and the
#       host is in an unexpected state. Silently reusing a wrong-type
#       switch would silently change traffic semantics (an Internal switch
#       in particular would re-expose the host vNIC the design just
#       removed).
# ---------------------------------------------------------------------------

function Initialize-PrivateSwitch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name
    )

    Write-Host ""
    Write-Host "--- Private switch: $Name ---" -ForegroundColor Cyan

    $existing = Get-VMSwitch -Name $Name -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        if ($existing.SwitchType -ne 'Private') {
            throw (
                "A switch named '$Name' already exists but is type " +
                "'$($existing.SwitchType)', expected 'Private'. Rename or " +
                "remove it before re-running."
            )
        }
        Write-Host "  Switch '$Name' already exists - skipping." `
            -ForegroundColor Green
        return
    }

    Write-Host "  Creating Private switch '$Name' ..."
    New-VMSwitch -Name $Name -SwitchType Private | Out-Null
    Write-Host "  [OK] Switch created." -ForegroundColor Green
}
