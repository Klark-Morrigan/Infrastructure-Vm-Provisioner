<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1 alongside the other up/seed/* helpers.
#>

# ---------------------------------------------------------------------------
# New-CloudInitMetaData
#   Returns the NoCloud meta-data file body. instance-id and local-hostname
#   are both keyed off the VM name: the one-VM-per-name model satisfies
#   cloud-init's "re-created instance changes id" requirement, and the
#   local-hostname line is what sets the Linux hostname on first boot.
#
#   Shared by the workload and router seed generators so the meta-data
#   shape is owned in one place.
# ---------------------------------------------------------------------------
function New-CloudInitMetaData {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $VmName
    )

    return @"
instance-id: $VmName
local-hostname: $VmName
"@
}
