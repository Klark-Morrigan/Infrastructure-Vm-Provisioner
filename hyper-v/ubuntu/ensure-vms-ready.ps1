<#
.SYNOPSIS
    Bring an already-provisioned Hyper-V Ubuntu fleet back to SSH-ready after
    a host reboot: power every VM on, then wait until each answers an SSH
    banner, walking each environment router-first.

.DESCRIPTION
    The host-reboot recovery action. Reads VmProvisionerConfig, powers the
    whole fleet on via Invoke-VmFleetPowerOn, then for each environment
    (grouped by privateSwitchName) checks reachability router-first:

      - Routers are readied before their workloads. A workload sits on a
        per-environment private switch the host has no route to (feature 53),
        so it is only reachable through a live router acting as its SSH jump
        host. A router that fails power-on or never answers marks itself
        Unreachable and short-circuits its workloads to
        "Unreachable (router not ready)" without a wasted tunnel attempt.
      - Standalone VMs (an environment with no router) are probed directly.

    "Ready" means powered + booted + an SSH- banner answering on port 22 -
    NOT a credentialed login. Reachability is delegated to the shared
    Wait-VmSshAccessible helper (the single source of truth create-vm.ps1
    also uses), so this script and provisioning agree on what "accessible"
    means. The reboot-recovery deadline is shorter than create-vm's
    first-boot budget: an existing VM is only rebooting, not installing.

    Idempotent: a fleet that is already up and reachable reports every VM
    Ready with exit code 0 and changes no Hyper-V state.

.NOTES
    REQUIREMENTS
    - Windows 11 with Hyper-V enabled.
    - Run as Administrator (Hyper-V cmdlets require elevation).
    - Microsoft.PowerShell.SecretManagement + Microsoft.PowerShell.SecretStore
      installed by setup-secrets.ps1.
    - PowerShell 7+.

    FAILURE POLICY
    - One bad VM never strands the rest. Power-on failures, router failures,
      and per-VM timeouts are recorded and folded into a final aggregate;
      exit code 1 if any VM is not Ready, 0 otherwise. The script never
      throws past the orchestration loop.

    RELATION TO start-vms.ps1
    - start-vms.ps1 is power-on only - the lighter path for an operator about
      to RDP. ensure-vms-ready.ps1 is power-on PLUS the readiness wait, for
      an operator about to SSH (or automation that needs the fleet reachable).

    SECURITY
    - No secrets are passed as command-line arguments or written to disk.
      All sensitive values are read at runtime from the encrypted vault.
#>

[CmdletBinding()]
param(
    # Required. See provision.ps1 for the suffix contract.
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SecretSuffix
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\common\config\Group-VmsByEnvironment.ps1"
. "$PSScriptRoot\common\config\Read-VmProvisionerConfig.ps1"
. "$PSScriptRoot\common\network\Resolve-ExistingRouterIp.ps1"
. "$PSScriptRoot\common\power\Invoke-VmFleetPowerOn.ps1"
. "$PSScriptRoot\common\ssh\Wait-VmSshAccessible.ps1"

# Reboot-recovery budget per VM. Deliberately shorter than create-vm's
# 10-minute first-boot window: an existing VM is only coming back from a
# reboot (no image download, no cloud-init install), so a long wait here
# means the VM is not coming back, not that it is still working. Revisit
# on the first real production run.
$readinessTimeoutMinutes = 5

# ---------------------------------------------------------------------------
# Invoke-VmReadinessWait (script-local)
#   Wraps a single Wait-VmSshAccessible call with the per-poll Hyper-V
#   state guard and the reboot-recovery deadline, and converts any throw
#   (the VM stopped mid-wait, a tunnel that could not open) into a plain
#   "not reachable" so the fleet loop is never stranded by one VM. Shared
#   by the router and workload branches so the wait contract has one home.
# ---------------------------------------------------------------------------
function Invoke-VmReadinessWait {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Vm,

        # The environment router for a workload, or $null for a router /
        # standalone VM (selects Wait-VmSshAccessible's direct-probe branch).
        [Parameter()]
        [AllowNull()]
        [object] $RouterVm
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

    # Caller owns the budget; compute the deadline per VM so a slow router
    # does not eat into a workload's window.
    $deadline = (Get-Date).AddMinutes($readinessTimeoutMinutes)

    try {
        $result = Wait-VmSshAccessible `
                      -Vm       $Vm `
                      -RouterVm $RouterVm `
                      -Deadline $deadline `
                      -OnPoll   $onPoll
        return [bool] $result.Reachable
    }
    catch {
        # A guard throw (VM stopped) or a tunnel-open failure means this VM
        # is not reachable. Record it as such and let the loop continue -
        # the readiness wait never propagates past the orchestration loop.
        return $false
    }
}

# ---------------------------------------------------------------------------
# 1. Install / import every required module via the centralised helper.
#    Brings Infrastructure.HyperV (Start-VmIfStopped, New-VmSshTunnel,
#    Get-VmKvpIpAddress) into scope alongside the SecretManagement provider
#    modules the bootstrap needs.
# ---------------------------------------------------------------------------

. "$PSScriptRoot\Install-ModuleDependencies.ps1"

# ---------------------------------------------------------------------------
# 2. Load + parse + validate the VmProvisionerConfig secret in one call.
#    Same contract as every sibling entry-point, so a bad config produces
#    byte-for-byte the same "Run setup-secrets.ps1 first" error regardless
#    of which entry-point the operator invoked.
# ---------------------------------------------------------------------------

$vmDefs = Read-VmProvisionerConfig -SecretSuffix $SecretSuffix

# ---------------------------------------------------------------------------
# 3. Power the whole fleet on.
#    Invoke-VmFleetPowerOn owns the per-VM Start-VmIfStopped loop with its
#    one-try/catch-per-VM isolation. A VM Hyper-V could not start cannot
#    become reachable, so its name is folded into the set excluded from the
#    readiness wait below.
# ---------------------------------------------------------------------------

$powerOn       = Invoke-VmFleetPowerOn -VmDefs $vmDefs
$failedPowerOn = @($powerOn.Failed | ForEach-Object { $_.VmName })

# ---------------------------------------------------------------------------
# 4. Readiness wait, router-first per environment.
#    Accumulates one { VmName; Status } per VM. Status is the per-VM line and
#    drives the aggregate buckets. The accumulator initialises to @() outside
#    the loop and appends inside so the .Count math below survives strict
#    mode's single-element unrolling.
# ---------------------------------------------------------------------------

$readiness = @()

foreach ($env in @(Group-VmsByEnvironment -VmDefs $vmDefs)) {
    $routers   = @($env.RouterVms)
    $workloads = @($env.WorkloadVms)

    # The jump host every workload in this environment tunnels through. An
    # environment with no router is standalone: workloads are probed
    # directly with -RouterVm $null and are not gated on a router.
    $jumpRouter   = if ($routers.Count -gt 0) { $routers[0] } else { $null }
    $routersReady = $true

    # Routers first - a workload can only be reached through a live router.
    foreach ($router in $routers) {
        if ($failedPowerOn -contains $router.vmName) {
            $readiness += [PSCustomObject]@{
                VmName = $router.vmName; Status = 'Power-on failed'
            }
            $routersReady = $false
            continue
        }

        # Stamp _state so Resolve-ExistingRouterIp takes its KVP path: every
        # VM this script sees is by definition already provisioned. A no-op
        # for a static router (the only supported mode - it already carries
        # ipAddress); the discovery path matters only for a non-static one.
        if (-not $router.PSObject.Properties['_state']) {
            Add-Member -InputObject $router -MemberType NoteProperty `
                       -Name '_state' -Value 'existing' -Force
        }
        Resolve-ExistingRouterIp -RouterVm $router

        Write-Host "  Waiting for router '$($router.vmName)' ..." -NoNewline
        if (Invoke-VmReadinessWait -Vm $router -RouterVm $null) {
            Write-Host ' ready' -ForegroundColor Green
            $readiness += [PSCustomObject]@{
                VmName = $router.vmName; Status = 'Ready'
            }
        }
        else {
            Write-Host ' unreachable' -ForegroundColor Red
            $readiness += [PSCustomObject]@{
                VmName = $router.vmName; Status = 'Unreachable'
            }
            $routersReady = $false
        }
    }

    # Workloads second - only attempted once their router is ready.
    foreach ($workload in $workloads) {
        if ($failedPowerOn -contains $workload.vmName) {
            $readiness += [PSCustomObject]@{
                VmName = $workload.vmName; Status = 'Power-on failed'
            }
            continue
        }

        # A dead router short-circuits its workloads with no tunnel attempt -
        # the forward could not open anyway. Standalone envs ($jumpRouter
        # $null) are never short-circuited.
        if ($null -ne $jumpRouter -and -not $routersReady) {
            $readiness += [PSCustomObject]@{
                VmName = $workload.vmName; Status = 'Unreachable (router not ready)'
            }
            continue
        }

        Write-Host "  Waiting for workload '$($workload.vmName)' ..." -NoNewline
        if (Invoke-VmReadinessWait -Vm $workload -RouterVm $jumpRouter) {
            Write-Host ' ready' -ForegroundColor Green
            $readiness += [PSCustomObject]@{
                VmName = $workload.vmName; Status = 'Ready'
            }
        }
        else {
            Write-Host ' unreachable' -ForegroundColor Red
            $readiness += [PSCustomObject]@{
                VmName = $workload.vmName; Status = 'Unreachable'
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 5. Per-VM lines + aggregate.
#    Each Where-Object filter is wrapped in @(...) before .Count to survive
#    the single-match scalar-unrolling trap under strict mode. "Unreachable
#    (router not ready)" rolls into the Unreachable bucket (it is one more
#    not-Ready VM); the per-VM line above keeps the precise reason.
# ---------------------------------------------------------------------------

Write-Host ""
foreach ($r in $readiness) {
    Write-Host ("{0}: {1}" -f $r.VmName, $r.Status)
}

$ready       = @($readiness | Where-Object { $_.Status -eq 'Ready'           }).Count
$powerFailed = @($readiness | Where-Object { $_.Status -eq 'Power-on failed' }).Count
$unreachable = @($readiness | Where-Object {
    $_.Status -ne 'Ready' -and $_.Status -ne 'Power-on failed'
}).Count

Write-Host ""
Write-Host ("Ready: {0}, Unreachable: {1}, Power-on failed: {2}" `
    -f $ready, $unreachable, $powerFailed) -ForegroundColor Cyan

# Exit 1 if any VM is not Ready - the single programmatic signal. Never
# throw past the loop, so automation gets a clean code, not a stack trace.
exit (($ready -eq $readiness.Count) ? 0 : 1)
