<#
.SYNOPSIS
    Computes the toUninstall / toInstall / noOp diff for one provider.

.DESCRIPTION
    Pure function over typed inputs: no SSH, no I/O. The orchestrator
    (Invoke-ToolchainReconciliation, step 4) calls this once per
    provider with the desired-versions array returned by the provider's
    Get-DesiredVersions and the installed-records array returned by its
    Get-InstalledVersions, then walks the resulting buckets in
    uninstall-then-install order.

    Three sentinels on -DesiredVersions are distinguished:

      $null   -> sub-field absent on the VM JSON. Result has
                 SkipProvider = $true and the installed set is passed
                 through as NoOp so a plan-log can still show what
                 happens to be on the VM.
      @()     -> sub-field present-but-empty (explicit null or []).
                 Every installed record is queued for uninstall.
      array   -> reconcile to exactly this set: match by Version.

    Provider identity is asserted defensively against each installed
    record so a caller that forgets to filter by provider fails loud
    here, instead of producing a cross-provider uninstall later.

.PARAMETER DesiredVersions
    $null, @(), or an array of typed spec objects (each with at least
    a Version property).

.PARAMETER InstalledVersions
    @() or an array of typed installed records (each with at least
    Provider and Version properties).

.PARAMETER ProviderName
    The provider this plan is being computed for. Used only to assert
    cross-provider records are not smuggled in via InstalledVersions.
#>
function Get-ProvisioningPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object] $DesiredVersions,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object] $InstalledVersions,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ProviderName
    )

    # Normalise installed to a concrete array so a single-element pipeline
    # does not scalar-unwrap under strict mode. $null entries are filtered
    # out for
    # the same reason - a hashtable-shaped record without a value yields
    # $null on dot-access which would break the Provider check below.
    $installed = @($InstalledVersions | Where-Object { $null -ne $_ })

    # Defensive: the orchestrator must hand each provider only its own
    # installed records. A mismatch here means the caller forgot to
    # filter; failing loud is far better than uninstalling another
    # provider's tools.
    foreach ($record in $installed) {
        if ($record.Provider -ne $ProviderName) {
            throw (
                "Get-ProvisioningPlan: installed record for provider " +
                "'$($record.Provider)' was passed under -ProviderName " +
                "'$ProviderName'. Caller must filter by provider before " +
                "diffing."
            )
        }
    }

    if ($null -eq $DesiredVersions) {
        # Sub-field absent: SkipProvider tells the orchestrator not to
        # even query installed versions for real (it already did, but
        # the contract is "skip"). NoOp carries the installed set
        # through for logging.
        return [PSCustomObject]@{
            ToUninstall  = @()
            ToInstall    = @()
            NoOp         = $installed
            SkipProvider = $true
        }
    }

    $desired = @($DesiredVersions | Where-Object { $null -ne $_ })

    if ($desired.Count -eq 0) {
        # Sub-field explicitly empty: reconcile to "ensure none".
        return [PSCustomObject]@{
            ToUninstall  = $installed
            ToInstall    = @()
            NoOp         = @()
            SkipProvider = $false
        }
    }

    # Match by Version. Provider identity was already asserted above,
    # so within this diff Version alone is sufficient.
    $installedVersions = @($installed | ForEach-Object { $_.Version })
    $desiredVersions   = @($desired   | ForEach-Object { $_.Version })

    $toInstall   = @($desired   | Where-Object { $installedVersions -notcontains $_.Version })
    $toUninstall = @($installed | Where-Object { $desiredVersions   -notcontains $_.Version })
    # NoOp carries the installed-side record (it has ManifestPath etc.)
    # rather than the desired-side spec, so log lines can name the
    # manifest that is being left alone.
    $noOp        = @($installed | Where-Object { $desiredVersions   -contains    $_.Version })

    return [PSCustomObject]@{
        ToUninstall  = $toUninstall
        ToInstall    = $toInstall
        NoOp         = $noOp
        SkipProvider = $false
    }
}
