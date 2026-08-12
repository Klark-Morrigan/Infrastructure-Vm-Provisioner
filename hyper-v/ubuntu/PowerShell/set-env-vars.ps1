<#
.SYNOPSIS
    Reconcile the operator-declared `envVars` managed block onto an
    already-provisioned Hyper-V Ubuntu fleet, without running a full
    provision.

.DESCRIPTION
    The PowerShell env engine as a standalone operator command - the peer of
    hyper-v/ubuntu/Ansible/ops/provision-env.sh, which is what the Ansible
    engine has had since it was written.

    Until this existed the PowerShell engine could only be reached as a step
    inside provision.ps1's post-provisioning. Re-applying one edited `envVars`
    block therefore meant a whole provision run: a vault read, the idempotency
    checks, the host-network phase and an SSH session per VM, to reach one
    step. That asymmetry is also why the two engines could not be handed a
    block back and forth cheaply - see the E2E engine hand-off in
    Infrastructure-E2E, which is this script's other caller.

    Reads VmProvisionerConfig, selects the VMs that declare `envVars`, and
    calls the same Set-EnvironmentVariables step provision.ps1 dispatches -
    so the two paths cannot drift. Everything a full provision does around
    that step is deliberately absent:

      - No host-network phase. The fleet is already up; creating switches or
        toggling ICS to write a text file would risk the very connectivity
        the write depends on.
      - No cloud-init wait. That is a first-boot concern.
      - No file server. Writing /etc/environment stages nothing host-side.

    What it does keep is the router jump. A workload sits on a per-environment
    private switch the host has no route into (feature 53), so its session is
    tunnelled through the environment's router exactly as post-provisioning
    tunnels its own - hence the _RouterVm stamping below.

    Idempotent: the transport skips the SSH write when the desired block
    already matches what is on disk, so a converged fleet reports every VM
    unchanged and touches nothing.

.PARAMETER SecretSuffix
    Required. See provision.ps1 for the suffix contract.

.PARAMETER VmName
    Optional. Restrict the run to the named VMs - the counterpart of
    provision-env.sh's `--limit`. An unmatched name is an error rather than a
    silent no-op: an operator who mistypes a VM name has asked for something
    that did not happen, and the whole point of a targeted run is knowing it
    reached its target.

.NOTES
    REQUIREMENTS
    - Windows 11 with Hyper-V enabled.
    - Run as Administrator (Hyper-V cmdlets require elevation).
    - PowerShell 7+, and the fleet already provisioned and reachable
      (ensure-vms-ready.ps1 is the recovery path after a host reboot).

    FAILURE POLICY
    - One bad VM never strands the rest: each VM's write is isolated, and the
      failures are folded into a final aggregate. Exit code 1 if any VM
      failed, 0 otherwise.

    RELATION TO THE ANSIBLE ENGINE
    - hyper-v/ubuntu/Ansible/ops/provision-env.sh does the same job through
      Common-Ansible's vm_env_vars role. The two write byte-identical managed
      blocks and each replaces the other's rather than appending a second one,
      so a host may be driven by either. See the README's "Which engine runs".

    SECURITY
    - No secrets are passed as command-line arguments or written to disk. All
      sensitive values are read at runtime from the encrypted vault. Note that
      /etc/environment is world-readable by design, so nothing secret belongs
      in a VM's `envVars` under either engine.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SecretSuffix,

    [Parameter()]
    [string[]] $VmName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\common\config\Group-VmsByEnvironment.ps1"
. "$PSScriptRoot\common\config\Read-VmProvisionerConfig.ps1"
. "$PSScriptRoot\common\network\Resolve-ExistingRouterIp.ps1"
. "$PSScriptRoot\up\post\Set-EnvironmentVariables.ps1"

# SSH open budget. Far shorter than post-provisioning's 10 minutes, and for a
# reason that matters: that budget exists to absorb cloud-init still running
# on a first boot. Here the VM is already up, so a slow connect means it is
# unreachable, not busy - and a fast failure is what tells the operator to run
# ensure-vms-ready.ps1 instead of watching a dead wait.
$sshOpenTimeout = [TimeSpan]::FromMinutes(2)

# ---------------------------------------------------------------------------
# 1. Modules, then config. Same two-step opening as every sibling
#    entry-point, so a bad config produces byte-for-byte the same
#    "Run setup-secrets.ps1 first" error whichever one the operator invoked.
#    Install-ModuleDependencies brings in Infrastructure.HyperV, which
#    exports the transport (Set-VmEnvironmentVariables) and the jump-aware
#    connect helper (New-VmSshClientWithJump) used below.
# ---------------------------------------------------------------------------

. "$PSScriptRoot\Install-ModuleDependencies.ps1"

$vmDefs = Read-VmProvisionerConfig -SecretSuffix $SecretSuffix

# ---------------------------------------------------------------------------
# 2. Select the targets.
#    Gate on field PRESENCE, not on entries.Count: `entries: []` is the
#    operator's explicit "remove the managed block" intent, so a VM declaring
#    it must still be visited. Same rule Invoke-VmPostProvisioning applies.
# ---------------------------------------------------------------------------

$targets = @($vmDefs | Where-Object { $_.PSObject.Properties['envVars'] })

if ($VmName) {
    $unmatched = @($VmName | Where-Object {
        $n = $_
        -not ($vmDefs | Where-Object { $_.vmName -eq $n })
    })
    if ($unmatched.Count -gt 0) {
        throw ("No VM named $($unmatched -join ', ') in " +
            "VmProvisionerConfig-$SecretSuffix.")
    }
    $targets = @($targets | Where-Object { $VmName -contains $_.vmName })
}

if ($targets.Count -eq 0) {
    Write-Host "No VM declares envVars - nothing to do." -ForegroundColor Cyan
    exit 0
}

# ---------------------------------------------------------------------------
# 3. Stamp each workload's jump host.
#    Grouping runs over the WHOLE config, not just the targets: a targeted
#    run on one workload still needs its environment's router, which may not
#    itself be a target. Routers are resolved before use because a router
#    definition carries its IP statically but a rebuilt one may not.
# ---------------------------------------------------------------------------

foreach ($environment in @(Group-VmsByEnvironment -VmDefs $vmDefs)) {
    $routers = @($environment.RouterVms)
    if ($routers.Count -eq 0) { continue }
    $router = $routers[0]

    # _state 'existing' sends Resolve-ExistingRouterIp down its KVP path.
    # Every VM this script sees is by definition already provisioned; the
    # stamp is a no-op for a static router, which already carries ipAddress.
    if (-not $router.PSObject.Properties['_state']) {
        Add-Member -InputObject $router -MemberType NoteProperty `
                   -Name '_state' -Value 'existing' -Force
    }
    Resolve-ExistingRouterIp -RouterVm $router

    foreach ($workload in @($environment.WorkloadVms)) {
        Add-Member -InputObject $workload -MemberType NoteProperty `
                   -Name '_RouterVm' -Value $router -Force
    }
}

# ---------------------------------------------------------------------------
# 4. Apply, one VM at a time.
#    New-VmSshClientWithJump branches on _RouterVm: a router (or a
#    pre-feature-53 VM) gets a direct session, a workload gets one tunnelled
#    through its router. The returned session owns both the client and the
#    tunnel, so disposing it tears them down in the right order.
# ---------------------------------------------------------------------------

$failures = @()

foreach ($vm in $targets) {
    Write-Host ""
    Write-Host "--- Environment variables: $($vm.vmName) ---" -ForegroundColor Cyan

    $session = $null
    try {
        $session = New-VmSshClientWithJump -Vm $vm -Timeout $sshOpenTimeout
        Set-EnvironmentVariables -SshClient $session.Client -Vm $vm
    }
    catch {
        # Recorded rather than rethrown: one unreachable VM must not strand
        # the rest of the fleet's edits. The aggregate below is what fails
        # the run.
        $failures += [PSCustomObject]@{
            VmName = $vm.vmName; Reason = $_.Exception.Message
        }
        Write-Host "  [envVars] FAILED - $($_.Exception.Message)" `
            -ForegroundColor Red
    }
    finally {
        if ($null -ne $session) {
            try { $session.Dispose() } catch { $null = $_ }
        }
    }
}

# ---------------------------------------------------------------------------
# 5. Aggregate.
# ---------------------------------------------------------------------------

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host ("Environment variables: $($failures.Count) of " +
        "$($targets.Count) VM(s) FAILED.") -ForegroundColor Red
    foreach ($f in $failures) {
        Write-Host "  $($f.VmName): $($f.Reason)" -ForegroundColor Red
    }
    exit 1
}

Write-Host "Environment variables applied to $($targets.Count) VM(s)." `
    -ForegroundColor Green
exit 0
