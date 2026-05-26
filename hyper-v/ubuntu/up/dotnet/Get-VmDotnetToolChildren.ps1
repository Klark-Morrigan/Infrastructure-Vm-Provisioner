<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1 and
    invoked from Get-DotnetSdkProvider at composition time.
#>

# ---------------------------------------------------------------------------
# Get-VmDotnetToolChildren
#   Builds the `{ provider, manifestPath }` records the children walker
#   reads, from two inputs:
#     1. `$Vm.dotnetTools` - the operator's declared (id, version) list.
#     2. The manifest filename grammar fixed by Write-VmManifest
#        (`{provider}-{version}.json` under the store directory) combined
#        with DotnetToolsProvider.Install-Version's choice of composite
#        `{id}-{rawVersion}` for that `version` field.
#   Both inputs are known at SDK-Install-Version time, so the returned
#   entries are exactly the paths the tools provider's Install-Version
#   will write at - no inference, no on-VM lookup.
#
#   Lives under hyper-v/ubuntu/up/dotnet/ alongside the SDK provider files
#   (not the tools provider's) so the parent-knows-children dependency
#   direction is visible from the directory layout: the SDK provider's
#   composer (Get-DotnetSdkProvider) is the only caller, and there is no
#   inverse dependency from the tools provider back to this helper.
#
#   Manifest filename grammar comes from Write-VmManifest:
#     /var/lib/infra-provisioner/manifests/{provider}-{version}.json
#   For dotnetTools the `version` field is the composite '{id}-{rawVersion}'
#   (see DotnetToolsProvider.Install-Version), so each child manifest path
#   is '/var/lib/infra-provisioner/manifests/dotnetTools-{id}-{rawVersion}.json'.
#
#   Returns @() (comma-operator wrapped to survive call-operator unrolling
#   in the SDK provider's closure - see feedback_powershell_return_empty_array
#   memory) for any VM that has no dotnetTools field, has it set to null,
#   or has it as an empty array. Operator entries are declaration-order-
#   preserving.
# ---------------------------------------------------------------------------
function Get-VmDotnetToolChildren {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Vm
    )

    if ($null -eq $Vm) { return ,@() }

    $prop = $Vm.PSObject.Properties['dotnetTools']
    if ($null -eq $prop -or $null -eq $prop.Value) {
        return ,@()
    }

    $entries = @($prop.Value)
    if ($entries.Count -eq 0) {
        return ,@()
    }

    $store = '/var/lib/infra-provisioner/manifests'

    $children = foreach ($entry in $entries) {
        $id      = [string]$entry.id
        $version = [string]$entry.version
        [PSCustomObject]@{
            provider     = 'dotnetTools'
            # Composite '{id}-{rawVersion}' matches the filename the
            # tools provider writes (Write-VmManifest concatenates
            # provider + '-' + version). If that grammar changes,
            # both sides have to change together.
            manifestPath = "$store/dotnetTools-$id-$version.json"
        }
    }

    return ,@($children)
}
