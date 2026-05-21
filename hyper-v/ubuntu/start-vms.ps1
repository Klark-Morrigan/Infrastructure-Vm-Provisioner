<#
.SYNOPSIS
    Start (or resume) every Hyper-V Ubuntu VM in the local VmProvisionerConfig
    vault entry.

.DESCRIPTION
    Reads the VmProvisionerConfig secret, validates each VM definition, then
    calls Start-VmIfStopped per VM. Idempotent: VMs already Running are
    reported as no-ops. A single bad VM (unknown to Hyper-V, in a transient
    state, etc.) does not strand the rest of the list - failures are
    aggregated and surfaced via exit code 1 after the loop.

    Run setup-secrets.ps1 once first to populate the vault, then provision.ps1
    to create the VMs. This script is the manual recovery path for hosts
    where Hyper-V's per-VM AutomaticStartAction is intentionally off (default
    for headless workstations to avoid surprise CPU/RAM consumption on boot).

.NOTES
    REQUIREMENTS
    - Windows 11 with Hyper-V enabled.
    - Run as Administrator (Hyper-V cmdlets require elevation).
    - Microsoft.PowerShell.SecretManagement + Microsoft.PowerShell.SecretStore
      installed by setup-secrets.ps1.
    - PowerShell 7+.

    IDEMPOTENCY
    - Already-Running VMs are no-ops (the per-VM state machine in
      Start-VmIfStopped owns the contract).
    - Saved VMs are resumed via Start-VM; the cmdlet itself is idempotent at
      the Hyper-V layer.

    FAILURE POLICY
    - One try/catch per VM. A failure for any single VM is recorded and the
      loop continues. Exit code 1 if any failure was recorded, 0 otherwise.
      The script never throws past the loop.

    SECURITY
    - No secrets are passed as command-line arguments or written to disk.
      All sensitive values are read at runtime from the encrypted vault.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\common\config\ConvertFrom-VmConfigJson.ps1"
. "$PSScriptRoot\common\config\Get-SanitizedVmDisplay.ps1"
. "$PSScriptRoot\common\config\Read-VmProvisionerConfig.ps1"

# ---------------------------------------------------------------------------
# 1. Install / import every required module via the centralised helper.
#    Brings Infrastructure.HyperV (which exports Start-VmIfStopped) into
#    scope alongside the SecretManagement provider modules the helper needs.
# ---------------------------------------------------------------------------

. "$PSScriptRoot\Install-ModuleDependencies.ps1"

# ---------------------------------------------------------------------------
# 2. Load + parse + validate the VmProvisionerConfig secret in one call.
#    Helper owns the SecretManagement bootstrap, vault read, and schema
#    validation - same contract used by provision.ps1 / deprovision.ps1, so
#    a bad config produces byte-for-byte the same operator-facing error
#    message regardless of which entry-point the operator invoked.
# ---------------------------------------------------------------------------

$vmDefs = Read-VmProvisionerConfig

# ---------------------------------------------------------------------------
# 3. Per-VM power-on
#    One try/catch around each Start-VmIfStopped call so a single failure
#    does not strand the rest of the list. Successful transitions land in
#    $transitions; failures land in $failed with the original exception
#    message. Both accumulators are initialised to @() outside the loop -
#    using an `if` expression here would yield $null on an empty match
#    under strict mode (Pester-5 unrolling trap).
# ---------------------------------------------------------------------------

$transitions = @()
$failed      = @()

Write-Host ""

foreach ($vm in $vmDefs) {
    try {
        $result = Start-VmIfStopped -VmName $vm.vmName
        $transitions += $result
        Write-Host ("{0}: {1} -> {2}" -f `
                    $result.VmName, $result.EntryState, $result.Action)
    }
    catch {
        $failed += [PSCustomObject]@{
            VmName = $vm.vmName
            Reason = $_.Exception.Message
        }
    }
}

# ---------------------------------------------------------------------------
# 4. Per-VM failure surfacing
#    Printed after the per-VM summaries so the operator sees the full
#    picture in chronological order: each VM's transition (or absence of
#    one) followed by the explicit list of failures with their reasons.
# ---------------------------------------------------------------------------

if ($failed.Count -gt 0) {
    Write-Host ""
    foreach ($f in $failed) {
        Write-Host ("{0}: FAILED - {1}" -f $f.VmName, $f.Reason) `
            -ForegroundColor Red
    }
}

# ---------------------------------------------------------------------------
# 5. Aggregate line
#    Bucketed via Group-Object on the per-VM Action so adding a new
#    transition type upstream surfaces here without code changes. Each
#    Where-Object filter is wrapped in @(...) before reading .Count to
#    survive the single-match scalar-unrolling trap under strict mode.
# ---------------------------------------------------------------------------

$started        = @($transitions | Where-Object { $_.Action -eq 'Started'        }).Count
$resumed        = @($transitions | Where-Object { $_.Action -eq 'Resumed'        }).Count
$alreadyRunning = @($transitions | Where-Object { $_.Action -eq 'AlreadyRunning' }).Count
$failedCount    = $failed.Count

Write-Host ""
Write-Host ("Started: {0}, Resumed: {1}, Already running: {2}, Failed: {3}" `
    -f $started, $resumed, $alreadyRunning, $failedCount) `
    -ForegroundColor Cyan

exit ($failedCount -gt 0 ? 1 : 0)
