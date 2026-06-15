<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    deprovision.ps1.
#>

# ---------------------------------------------------------------------------
# Invoke-VmRemoval
#   Stops and deletes a Hyper-V VM, then removes its VHDX, seed ISO, and
#   VM configuration directory.
#
#   Steps performed:
#     1. Check whether the VM exists in Hyper-V.
#        - If present: Stop (when running), then Remove-VM.
#        - If absent: skip Hyper-V teardown (idempotent re-run after partial
#          failure - VM may have been removed but file cleanup did not finish).
#     2. Delete the per-VM VHDX with a file-lock retry policy.
#        Windows VMMS releases its handle on the VHDX asynchronously after
#        Remove-VM returns. Immediate deletion would throw IOException. Up to
#        5 attempts with exponential backoff (capped at 30 s); throws on
#        exhaustion identifying the locked path so the operator can re-run
#        when the handle is freed. Retry is provided by Invoke-WithRetry
#        (Common.PowerShell) with New-FileLockRetryStrategy.
#     3. Delete the seed ISO if present. Absence is not an error - provision.ps1
#        removes it after first boot, so it is routinely absent.
#     4. Delete the VM configuration directory with the same retry policy as
#        the VHDX (Hyper-V config files are also held by VMMS until it flushes).
# ---------------------------------------------------------------------------
function Invoke-VmRemoval {
    [CmdletBinding()]
    param(
        # VM config object as produced by ConvertFrom-VmConfigJson.
        [Parameter(Mandatory)]
        [object] $Vm
    )

    Write-Host ""
    Write-Host "--- Removing VM: $($Vm.vmName) ---" -ForegroundColor Cyan

    # ------------------------------------------------------------------
    # Step 1 - Hyper-V teardown
    # ------------------------------------------------------------------
    $existingVm = Get-VM -Name $Vm.vmName -ErrorAction SilentlyContinue
    if ($null -ne $existingVm) {
        if ($existingVm.State -ne 'Off') {
            Write-Host "  Stopping VM ..."
            Stop-VM -Name $Vm.vmName -Force
        }
        Write-Host "  Removing VM from Hyper-V ..."
        Remove-VM -Name $Vm.vmName -Force
        Write-Host "  [OK] VM removed from Hyper-V." -ForegroundColor Green
    }
    else {
        Write-Host "  VM not found in Hyper-V - skipping Hyper-V teardown." `
            -ForegroundColor Yellow
    }

    # ------------------------------------------------------------------
    # Step 2 - VHDX deletion (with VMMS handle-release retry)
    # ------------------------------------------------------------------
    $vhdxPath = Join-Path $Vm.vhdPath "$($Vm.vmName).vhdx"
    if (Test-Path $vhdxPath) {
        Invoke-WithRetry `
            -OperationName "delete $vhdxPath" `
            -RetryStrategy (New-FileLockRetryStrategy) `
            -MaxAttempts   5 `
            -ScriptBlock   {
                Remove-Item -Path $vhdxPath -Recurse -Force -ErrorAction Stop
            }
        Write-Host "  [OK] VHDX deleted." -ForegroundColor Green
    }

    # ------------------------------------------------------------------
    # Step 3 - Seed ISO deletion (no retry - not held by VMMS)
    # ------------------------------------------------------------------
    $seedIsoPath = Join-Path $Vm.vmConfigPath "$($Vm.vmName)-seed.iso"
    if (Test-Path $seedIsoPath) {
        Remove-Item -Path $seedIsoPath -Force
        Write-Host "  [OK] Seed ISO deleted." -ForegroundColor Green
    }

    # ------------------------------------------------------------------
    # Step 4 - VM configuration directory deletion (with retry)
    # ------------------------------------------------------------------
    $vmConfigDir = Join-Path $Vm.vmConfigPath $Vm.vmName
    if (Test-Path $vmConfigDir) {
        Invoke-WithRetry `
            -OperationName "delete $vmConfigDir" `
            -RetryStrategy (New-FileLockRetryStrategy) `
            -MaxAttempts   5 `
            -ScriptBlock   {
                Remove-Item -Path $vmConfigDir -Recurse -Force -ErrorAction Stop
            }
        Write-Host "  [OK] VM config directory deleted." -ForegroundColor Green
    }

    Write-Host "  [OK] $($Vm.vmName) removed." -ForegroundColor Green
}
