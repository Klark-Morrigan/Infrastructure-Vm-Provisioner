<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1 after iso.ps1 (New-SeedIso must be available).
#>

# ---------------------------------------------------------------------------
# Write-VmSeedIso
#   Writes the NoCloud seed ISO for a VM and records its path on the VM
#   object for downstream use by Invoke-VmCreation.
#
#   The output path is derived from $Vm.vmConfigPath and $Vm.vmName so
#   workload and router seeds land in the same per-VM directory, and the
#   "_seedIsoPath" note property is written via Add-Member with -Force
#   so a re-run on the same VM object overwrites a stale value rather
#   than throwing.
#
#   Shared by the workload and router seed generators so the path
#   construction, the New-SeedIso invocation, and the _seedIsoPath
#   contract live in one place.
# ---------------------------------------------------------------------------
function Write-VmSeedIso {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Vm,

        [Parameter(Mandatory)]
        [string] $MetaData,

        [Parameter(Mandatory)]
        [string] $UserData,

        [Parameter(Mandatory)]
        [string] $NetworkConfig
    )

    $seedIsoPath = Join-Path $Vm.vmConfigPath "$($Vm.vmName)-seed.iso"
    Write-Host "  Writing: $seedIsoPath"

    New-SeedIso -OutputPath $seedIsoPath -Files @{
        'meta-data'      = $MetaData
        'user-data'      = $UserData
        'network-config' = $NetworkConfig
    }

    Write-Host "  [OK] Seed ISO ready: $seedIsoPath" -ForegroundColor Green

    Add-Member -InputObject $Vm -MemberType NoteProperty `
               -Name '_seedIsoPath' -Value $seedIsoPath -Force
}
