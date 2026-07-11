<#
.NOTES
    Do not run this file directly. Dot-sourced by ensure-vms-ready.ps1.
#>

# Invoke-VmReadinessWait does the actual wait + error capture; this helper
# is the presentation/aggregation layer over it. Dot-sourced here so a
# consumer imports this one file and gets the whole readiness-status chain
# wired, the same single-entry-point shape the rest of common/ uses.
. "$PSScriptRoot\Invoke-VmReadinessWait.ps1"

# ---------------------------------------------------------------------------
# Resolve-VmReadinessStatus
#   Drives the readiness wait for one VM, paints the operator progress line
#   ("Waiting for <kind> '<vm>' ... ready|unreachable"), surfaces the failure
#   reason when the wait threw, and returns the status string the caller
#   folds into its readiness aggregate. Shared by ensure-vms-ready.ps1's
#   router and workload branches so the wait-and-report shape lives in one
#   place.
#
#   Returns 'Ready' when an SSH banner answered, 'Unreachable' otherwise.
#   The richer power-on-failed / router-not-ready statuses are the caller's
#   concern - those VMs never reach a wait, so they never reach this helper.
# ---------------------------------------------------------------------------
function Resolve-VmReadinessStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Vm,

        # The environment router for a workload, or $null for a router /
        # standalone VM. Forwarded to Invoke-VmReadinessWait unchanged.
        [Parameter()]
        [AllowNull()]
        [object] $RouterVm,

        # 'router' or 'workload' - only shapes the progress-line wording.
        [Parameter(Mandatory)]
        [string] $Kind,

        # Reboot-recovery budget in minutes, forwarded to the wait.
        [Parameter(Mandatory)]
        [int] $TimeoutMinutes
    )

    Write-Host "  Waiting for $Kind '$($Vm.vmName)' ..." -NoNewline
    $result = Invoke-VmReadinessWait `
                  -Vm $Vm -RouterVm $RouterVm -TimeoutMinutes $TimeoutMinutes
    if ($result.Reachable) {
        Write-Host ' ready' -ForegroundColor Green
        return 'Ready'
    }

    Write-Host ' unreachable' -ForegroundColor Red
    # A clean timeout has no Error; only print a reason when the wait threw,
    # so the operator can tell a still-booting VM from a power / network fault.
    if ($result.Error) {
        Write-Host ("    reason: {0}" -f $result.Error) -ForegroundColor Yellow
    }
    return 'Unreachable'
}
