<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1.
#>

# ---------------------------------------------------------------------------
# Ensure-ExternalSwitch
#   Idempotently makes sure a Hyper-V External switch named <Name> exists on
#   the host. Used by feature 53 (router VM) so the operator only declares
#   the switch and the physical adapter it should bind to; provisioning
#   creates the switch when absent and reuses it when present. Sibling of
#   Ensure-PrivateSwitch.
#
#   -AllowManagementOS:$true is non-negotiable: the physical NIC the
#   switch binds to is typically the host's only path to the network, so
#   creating an External switch WITHOUT the management OS share would
#   strand the host (and the operator) the moment New-VMSwitch returns.
#
#   Idempotent:
#     - If no switch with that name exists, create it as External bound
#       to NetAdapterName.
#     - If a switch with that name already exists AND its type is
#       External OR Internal, log and return. Both can carry the
#       router's upstream traffic: External bridges to a physical NIC,
#       Internal pairs with Windows Internet Connection Sharing (ICS)
#       to NAT the router's egress through the host. The ICS path is
#       the durable answer on Wi-Fi-only hosts where the External
#       bridge collides VM IPs with the host (memory:
#       hyperv-internal-plus-ics). The bound adapter (External) or
#       ICS pairing (Internal) is the operator's choice and we do not
#       second-guess it.
#     - If a switch with that name exists but is type Private, throw -
#       Private switches have no upstream egress at all, and silently
#       reusing one would strand the router. The operator has to
#       resolve the collision.
#     - If the named NetAdapter is missing when creation is needed,
#       throw with the Get-NetAdapter hint so the operator can find the
#       correct name on the host.
# ---------------------------------------------------------------------------

function Ensure-ExternalSwitch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $NetAdapterName
    )

    Write-Host ""
    Write-Host "--- External switch: $Name ---" -ForegroundColor Cyan

    $existing = Get-VMSwitch -Name $Name -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        if ($existing.SwitchType -notin @('External', 'Internal')) {
            throw (
                "A switch named '$Name' already exists but is type " +
                "'$($existing.SwitchType)', expected 'External' or " +
                "'Internal' (External for direct bridging, Internal " +
                "paired with Windows ICS for the Wi-Fi-only NAT path). " +
                "Rename or remove it before re-running."
            )
        }
        Write-Host "  Switch '$Name' already exists (type: $($existing.SwitchType)) - skipping." `
            -ForegroundColor Green
        return
    }

    # Verify the named adapter exists before calling New-VMSwitch so the
    # error message points the operator at the right diagnostic command
    # rather than the generic Hyper-V "could not create switch".
    $adapter = Get-NetAdapter -Name $NetAdapterName -ErrorAction SilentlyContinue
    if ($null -eq $adapter) {
        throw (
            "Network adapter '$NetAdapterName' not found on the host. Run " +
            "Get-NetAdapter to see available adapter names, then update " +
            "the VM config's 'externalAdapterName' field."
        )
    }

    Write-Host "  Creating External switch '$Name' bound to '$NetAdapterName' ..."
    # AllowManagementOS:$true keeps the host on the network through this
    # NIC. Without it the host loses its connection the moment New-VMSwitch
    # returns - typically the operator's only remote-access path.
    New-VMSwitch -Name              $Name `
                 -NetAdapterName    $NetAdapterName `
                 -AllowManagementOS $true | Out-Null
    Write-Host "  [OK] Switch created." -ForegroundColor Green
}
