<#
.NOTES
    Do not run this file directly. Dot-sourced by start-vms.ps1.
#>

# ---------------------------------------------------------------------------
# Invoke-VmFleetPowerOn
#   Single source of truth for "power on the whole stored fleet". Owns the
#   per-VM Start-VmIfStopped loop: one try/catch per VM so a single bad VM
#   (unknown to Hyper-V, in a transient state, etc.) never strands the rest
#   of the list. Successful transitions accumulate in Transitions; failures
#   accumulate in Failed.
#
#   Returns one PSCustomObject:
#       Transitions : array of the Start-VmIfStopped result objects
#                     ({ VmName, EntryState, Action }), in input order
#       Failed      : array of { VmName, Reason } for VMs whose power-on
#                     threw, carrying the original exception message
#
#   Presentation and exit-code policy stay with the caller: this helper
#   does NO Write-Host and NO exit. start-vms.ps1 formats the summary and
#   exits on Failed.Count. Returning the two buckets (rather than printing
#   and exiting here) lets a caller fold Failed into a larger aggregate -
#   e.g. excluding a VM Hyper-V could not start from a downstream
#   reachability wait, since it cannot become reachable.
# ---------------------------------------------------------------------------
function Invoke-VmFleetPowerOn {
    [CmdletBinding()]
    param(
        # VM definitions from VmProvisionerConfig. Only vmName is consulted
        # here; the rest of the def is the caller's concern. Empty is
        # allowed and yields both buckets empty with no Start-VmIfStopped
        # call.
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $VmDefs
    )

    # Both accumulators initialise to @() outside the loop and append
    # inside. An `if`/pipeline expression here would yield $null (or a
    # bare scalar on a single element) under strict mode, so the explicit
    # @() keeps them arrays for the caller's .Count math.
    $transitions = @()
    $failed      = @()

    foreach ($vm in $VmDefs) {
        try {
            $transitions += Start-VmIfStopped -VmName $vm.vmName
        }
        catch {
            $failed += [PSCustomObject]@{
                VmName = $vm.vmName
                Reason = $_.Exception.Message
            }
        }
    }

    [PSCustomObject]@{
        Transitions = $transitions
        Failed      = $failed
    }
}
