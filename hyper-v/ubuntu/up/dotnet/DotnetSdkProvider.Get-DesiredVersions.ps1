<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    Get-DotnetSdkProvider, which composes the four provider operations
    into a single IToolchainProvider object.
#>

# ---------------------------------------------------------------------------
# Get-DotnetSdkDesiredVersions
#   Parses the optional 'dotnetSdk' field on a VM definition into the
#   typed spec shape consumed by the reconciler (see Provider-Contract.ps1):
#       [PSCustomObject]@{ Provider='dotnetSdk'; Channel; RequestedVersion;
#                          Version; TarballPath }
#
#   Spec.Version is the *resolved* SDK version (e.g. '10.0.100') so the
#   reconciler's diff (which matches desired vs installed by Version)
#   compares the same shape on both sides - Get-InstalledVersions reads
#   the resolved version from the on-VM manifest, and the manifest was
#   written with the resolved version too. Without this alignment, every
#   no-op run would falsely schedule a reinstall because the operator-
#   literal '10.0' never equals the resolver's '10.0.100'.
#
#   RequestedVersion preserves the operator's literal pin (e.g. '10',
#   '10.0', '10.0.100') for log output and downstream tooling. It does
#   NOT participate in the diff. Channel travels through for the same
#   diagnostic reason.
#
#   TarballPath is the host-side cached tarball location stamped onto
#   $Vm by Invoke-DotnetSdkAcquisition. The provider's Install-Version
#   forwards it to Expand-VmTarball so the VM-side install does not have
#   to re-derive the cache layout.
#
#   The resolved version is sourced from $Vm._dotnetSdkResolvedVersion,
#   stamped by Invoke-DotnetSdkAcquisition in the host-side acquisitions
#   phase (which runs before post-provisioning reconciliation). Missing
#   field => acquisition did not run for this VM => loud throw rather
#   than silent reinstall.
#
#   Two input shapes are accepted (the validator in Assert-DotnetSdkField
#   already caps the list to length 1):
#       dotnetSdk: { channel, version }              (scalar)
#       dotnetSdk: [{ channel, version }, ...]       (list)
#
#   Return values follow the provider contract:
#       absent field    -> $null  (orchestrator skips this provider)
#       explicit null   -> @()    ("ensure none installed")
#       explicit []     -> @()    (same)
#       one entry       -> array of one Spec record
# ---------------------------------------------------------------------------

function Get-DotnetSdkDesiredVersions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $VmConfig
    )

    # Absent field is the "skip this provider" signal in the contract.
    # Distinguished from explicit null / [] so an operator who removes
    # the field entirely is not surprised by an uninstall.
    if (-not $VmConfig.PSObject.Properties['dotnetSdk']) {
        return $null
    }

    $sdk = $VmConfig.dotnetSdk

    # Explicit null in the JSON (dotnetSdk: null) -> ensure-none.
    if ($null -eq $sdk) {
        # Comma-operator wrap: a bare `return @()` unrolls the empty
        # array on the output stream, which the caller sees as $null -
        # the reconciler would then misread the operator's explicit
        # ensure-none intent as "skip this provider". `,@()` preserves
        # the array shape across the function boundary.
        return ,@()
    }

    # Normalise scalar (JSON object -> PSCustomObject) vs list (JSON array
    # -> object[]) into a single iterable. Wrapping with @(...) collapses
    # the scalar case to a one-element array and leaves the list case
    # unchanged.
    if ($sdk -is [System.Management.Automation.PSCustomObject]) {
        $entries = @($sdk)
    }
    elseif ($sdk -is [array]) {
        $entries = @($sdk)
    }
    else {
        throw (
            "dotnetSdk must be a JSON object or array of objects; " +
            "got [$($sdk.GetType().FullName)]."
        )
    }

    # Explicit [] in the JSON -> ensure-none. Counted post-wrap so the
    # check fires for both an empty array literal and the (degenerate)
    # case of an array that flattened to zero entries.
    if ($entries.Count -eq 0) {
        return ,@()
    }

    # v1 hard-cap mirrors Assert-DotnetSdkField. Defensive: the validator
    # should have caught this already, but the provider may be invoked
    # through a path that bypasses schema validation.
    if ($entries.Count -gt 1) {
        throw (
            "dotnetSdk v1 supports one SDK per VM; got $($entries.Count) " +
            "entries."
        )
    }

    $entry = $entries[0]

    # Resolved version must already be on the VM object (Invoke-DotnetSdkAcquisition
    # stamps it in the host-side acquisitions phase). Absence here means
    # the pipeline ran out of order or the acquisition silently skipped -
    # either way, proceeding would compare a literal '10.0' against a
    # manifest's '10.0.100' and force a reinstall every run.
    if (-not $VmConfig.PSObject.Properties['_dotnetSdkResolvedVersion'] -or
        [string]::IsNullOrWhiteSpace($VmConfig._dotnetSdkResolvedVersion)) {
        throw (
            "Get-DotnetSdkDesiredVersions: VmConfig is missing " +
            "_dotnetSdkResolvedVersion. Invoke-DotnetSdkAcquisition must " +
            "run for this VM before the reconciler's desired-versions query."
        )
    }

    # TarballPath is required by Install-Version. Same reasoning as the
    # resolved-version guard above: a missing tarball stamp means the
    # acquisition did not run, and Install-Version would otherwise fail
    # later with a less-actionable error.
    if (-not $VmConfig.PSObject.Properties['_dotnetSdkTarballPath'] -or
        [string]::IsNullOrWhiteSpace($VmConfig._dotnetSdkTarballPath)) {
        throw (
            "Get-DotnetSdkDesiredVersions: VmConfig is missing " +
            "_dotnetSdkTarballPath. Invoke-DotnetSdkAcquisition must " +
            "run for this VM before the reconciler's desired-versions query."
        )
    }

    # Comma-operator return prevents PowerShell from unwrapping the
    # one-element array on the way back out - the contract specifies
    # "array of typed spec objects" and downstream code calls .Count on
    # it.
    return ,@(
        [PSCustomObject]@{
            Provider         = 'dotnetSdk'
            Channel          = $entry.channel
            RequestedVersion = $entry.version
            Version          = $VmConfig._dotnetSdkResolvedVersion
            TarballPath      = $VmConfig._dotnetSdkTarballPath
        }
    )
}
