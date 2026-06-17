<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1.
#>

# ---------------------------------------------------------------------------
# Remove-VmSeedIso
#   Detaches the seed-ISO DVD drive from a Hyper-V VM (when attached) and
#   deletes the ISO file from disk (when present). Idempotent: safe to call
#   when the DVD drive was never attached, when the ISO was never written,
#   or when both were already cleaned up by a prior call.
#
#   Why both steps in one function:
#     Remove-VMDvdDrive must run BEFORE Remove-Item - deleting an ISO that
#     is still attached as a DVD leaves a broken DVD drive reference on
#     the VM that the next provision run trips over. The ordering is
#     load-bearing, so the pair lives together.
#
#   Why it always runs:
#     The seed ISO carries the plaintext admin password cloud-init reads
#     on first boot. Leaving it on disk after provisioning is never
#     acceptable - the cleanup belongs in create-vm.ps1's finally block
#     and runs regardless of whether SSH succeeded or timed out.
# ---------------------------------------------------------------------------
function Remove-VmSeedIso {
    [CmdletBinding()]
    param(
        # Hyper-V VM name. Required because the Get-VMDvdDrive lookup
        # is by VM, not by ISO path.
        [Parameter(Mandatory)]
        [string] $VmName,

        # Full host-side path to the seed ISO file. The function also
        # uses this to find the matching DVD drive (a VM can have
        # multiple DVD drives attached; we only remove the one whose
        # Path equals this value).
        [Parameter(Mandatory)]
        [string] $SeedIsoPath
    )

    # Find ONLY the DVD drive whose Path is the seed ISO. A VM may
    # have unrelated DVDs attached (the operator's own diagnostic
    # bootable, for example); leaving those untouched is the
    # principle of least surprise.
    $dvdDrive = Get-VMDvdDrive -VMName $VmName |
        Where-Object { $_.Path -eq $SeedIsoPath }
    if ($null -ne $dvdDrive) {
        Remove-VMDvdDrive -VMName             $VmName `
                          -ControllerNumber   $dvdDrive.ControllerNumber `
                          -ControllerLocation $dvdDrive.ControllerLocation
    }
    if (Test-Path $SeedIsoPath) {
        Remove-Item -Path $SeedIsoPath -Force
        Write-Host "  [OK] Seed ISO removed." -ForegroundColor Green
    }
}
