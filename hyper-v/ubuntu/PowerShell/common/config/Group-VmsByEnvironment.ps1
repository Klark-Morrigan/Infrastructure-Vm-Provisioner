<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1 and deprovision.ps1.
#>

# ---------------------------------------------------------------------------
# Group-VmsByEnvironment
#   Single source of truth for the per-environment view that feature 53
#   step 2 introduced. Groups the input VM definitions by
#   'privateSwitchName' and splits each group into its router VM(s) and
#   workload VMs.
#
#   Returns one PSCustomObject per unique privateSwitchName:
#       Name          : the private switch name (the environment key)
#       RouterVms     : array of router VM definitions in this env
#       WorkloadVms   : array of workload VM definitions in this env
#
#   Empty input is allowed and yields an empty array. RouterVms /
#   WorkloadVms may be empty arrays - callers iterate them with @() and
#   handle the zero case explicitly.
#
#   This helper does NOT validate (no "exactly one router VM" rule, no
#   gateway-matches-router check). Validation lives in
#   Select-VmsForProvisioning's Assert-EnvironmentConsistency, which
#   builds on top of this helper. Keeping the grouping operation pure
#   means deprovision.ps1 (which does not run preflight) can call it
#   safely against any config shape and decide per-environment what to
#   do with the result.
# ---------------------------------------------------------------------------
function Group-VmsByEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $VmDefs
    )

    # Group-Object keeps source order inside each group, so callers that
    # surface per-VM error messages reference VMs in the order the
    # operator wrote them.
    $groups = $VmDefs | Group-Object -Property privateSwitchName

    foreach ($group in $groups) {
        [PSCustomObject]@{
            Name        = $group.Name
            RouterVms   = @($group.Group | Where-Object { $_.kind -eq 'router' })
            WorkloadVms = @($group.Group | Where-Object { $_.kind -ne 'router' })
        }
    }
}
