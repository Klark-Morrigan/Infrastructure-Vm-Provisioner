<#
.NOTES
    Do not run this file directly. Dot-sourced by Resolve-VmReadinessStatus.ps1
    (which ensure-vms-ready.ps1 loads).
#>

# Wait-VmSshAccessible is the reachability primitive this readiness wrapper
# drives; dot-sourced here so a consumer imports this one file and gets the
# probe wired, rather than having to dot-source the chain itself. Same
# single-entry-point shape Read-VmProvisionerConfig uses for
# ConvertFrom-VmConfigJson.
. "$PSScriptRoot\Wait-VmSshAccessible.ps1"

# ---------------------------------------------------------------------------
# Invoke-VmReadinessWait
#   Wraps a single Wait-VmSshAccessible call with the per-poll Hyper-V state
#   guard and a reboot-recovery deadline. Returns a result the caller can act
#   on without the readiness wait ever propagating past the orchestration
#   loop:
#       Reachable : $true once an SSH banner answers, $false otherwise.
#       Error     : $null on a clean timeout (the VM simply never answered
#                   within the deadline); the exception message when the wait
#                   threw instead (VM stopped mid-wait, a tunnel that could
#                   not open, a probe that errored). Surfacing the reason -
#                   rather than collapsing every failure to a bare
#                   "Unreachable" - is what lets the operator tell a
#                   still-booting VM apart from a networking / power fault.
# ---------------------------------------------------------------------------
function Invoke-VmReadinessWait {
    [CmdletBinding()]
    param(
        # The VM definition to reach. Passed straight through to
        # Wait-VmSshAccessible, which picks the probe endpoint by VM kind.
        [Parameter(Mandatory)]
        [object] $Vm,

        # The environment router for a workload, or $null for a router /
        # standalone VM (selects Wait-VmSshAccessible's direct-probe branch).
        [Parameter()]
        [AllowNull()]
        [object] $RouterVm,

        # Reboot-recovery budget in minutes. The caller owns it so the per-VM
        # deadline is computed here, fresh, rather than shared across VMs.
        [Parameter(Mandatory)]
        [int] $TimeoutMinutes
    )

    # The Hyper-V "VM no longer Running" early-exit, forwarded as -OnPoll.
    # Closes over a plain string ($vmName) rather than $Vm.vmName so the
    # callback resolves the same way when invoked from another session
    # state, matching create-vm.ps1's pattern.
    $vmName = $Vm.vmName
    $onPoll = {
        $vmState = (Get-VM -Name $vmName).State
        if ($vmState -ne 'Running') {
            Write-Host ''
            throw "VM '$vmName' is no longer Running (state: $vmState)."
        }
    }.GetNewClosure()

    # Compute the deadline per VM so a slow router does not eat into a
    # workload's window.
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)

    try {
        $result = Wait-VmSshAccessible `
                      -Vm       $Vm `
                      -RouterVm $RouterVm `
                      -Deadline $deadline `
                      -OnPoll   $onPoll
        return [PSCustomObject]@{ Reachable = [bool] $result.Reachable; Error = $null }
    }
    catch {
        # A guard throw (VM stopped), a tunnel-open failure, or a probe error
        # is not reachable - but it is NOT a clean timeout, so carry the
        # reason back for the caller to print rather than hiding it behind a
        # bare "Unreachable".
        return [PSCustomObject]@{ Reachable = $false; Error = $_.Exception.Message }
    }
}
