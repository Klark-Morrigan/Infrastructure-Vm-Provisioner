<#
.SYNOPSIS
    Projects each VM's toolchain fields into a per-host map keyed by vmName -
    the shape the staging step resolves and the toolchain playbook looks up
    per host.

.DESCRIPTION
    The PowerShell reconciler authored toolchains per VM (javaDevKit /
    dotnetSdk / dotnetTools on each VM definition). The Ansible flow preserves
    that per-VM targeting: the bridge keys inventory hosts by vmName, and the
    consumer playbook selects each host's own toolchains by inventory_hostname
    from the resolved map this function seeds. So the projection is per host,
    NOT a fleet union:

        per-VM { javaDevKit, dotnetSdk, dotnetTools }
            -> { <vmName>: { jdk_versions, dotnet_sdk_versions,
                            dotnet_tools_tools }, ... }

    Rules:
      - javaDevKit {vendor,version} (scalar or 1-list) contributes its bare
        `version` to that host's jdk_versions. The vendor is dropped because
        the jdk role hardcodes temurin (the only vendor the config validator
        accepts), so carrying it would be dead data.
      - dotnetSdk {channel,version} and dotnetTools {id,version} entries match
        the role-var entry shapes 1:1 and pass through verbatim.
      - null / [] / an absent field contributes nothing for that host.
      - Router VMs are skipped: the schema rejects toolchain fields on routers,
        and the bridge drops them from the inventory anyway.
      - A VM that requests no toolchains at all is omitted from the map; the
        playbook's per-host lookup defaults an absent host to "install nothing".
      - Within a single VM, repeated pins are de-duplicated (first-seen order).

    Pure and side-effect free: it reads only the objects handed in and returns
    a new object, so it is unit-testable without secrets or a VM. The caller
    (Stage-ToolchainArtifacts.ps1) reads and validates the VM definitions (via
    Read-VmProvisionerConfig) before calling this.

.PARAMETER VmConfigs
    The array of validated VM-definition objects (as returned by
    Read-VmProvisionerConfig). An empty array yields an empty map.

.OUTPUTS
    A PSCustomObject whose property names are vmNames and whose values are
    { jdk_versions (string[]), dotnet_sdk_versions ({channel,version}[]),
    dotnet_tools_tools ({id,version}[]) }.
#>
function ConvertTo-PerVmToolchainConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $VmConfigs
    )

    # Ordered so the emitted map is stable/diffable across runs.
    $byHost = [ordered]@{}

    # The Mandatory [object[]] contract rejects a null-containing array at the
    # binding boundary, so every element here is a real VM object.
    foreach ($vm in $VmConfigs) {

        # Routers reject toolchain fields by schema and are absent from the
        # inventory; skip them so a stray field can never leak in.
        $kind = if ($vm.PSObject.Properties['kind']) { [string]$vm.kind } else { '' }
        if ($kind -eq 'router') { continue }

        # Seen-sets carry a distinct suffix (PowerShell variable names are
        # case-insensitive, so $tools and $toolS would be the SAME variable).
        $jdk      = [System.Collections.Generic.List[string]]::new()
        $jdkSeen  = [System.Collections.Generic.HashSet[string]]::new()
        $sdk      = [System.Collections.Generic.List[object]]::new()
        $sdkSeen  = [System.Collections.Generic.HashSet[string]]::new()
        $tools    = [System.Collections.Generic.List[object]]::new()
        $toolSeen = [System.Collections.Generic.HashSet[string]]::new()

        foreach ($entry in (Get-VmToolchainFieldEntries -Vm $vm -FieldName 'javaDevKit')) {
            $version = [string]$entry.version
            if ([string]::IsNullOrWhiteSpace($version)) { continue }
            if ($jdkSeen.Add($version)) { $jdk.Add($version) }
        }

        foreach ($entry in (Get-VmToolchainFieldEntries -Vm $vm -FieldName 'dotnetSdk')) {
            $channel = [string]$entry.channel
            $version = [string]$entry.version
            if ($sdkSeen.Add("$channel|$version")) {
                $sdk.Add([PSCustomObject]@{ channel = $channel; version = $version })
            }
        }

        foreach ($entry in (Get-VmToolchainFieldEntries -Vm $vm -FieldName 'dotnetTools')) {
            $id      = [string]$entry.id
            $version = [string]$entry.version
            if ($toolSeen.Add("$id|$version")) {
                $tools.Add([PSCustomObject]@{ id = $id; version = $version })
            }
        }

        # A VM with no toolchains at all is omitted; the playbook defaults an
        # absent host to "install nothing".
        if ($jdk.Count -eq 0 -and $sdk.Count -eq 0 -and $tools.Count -eq 0) {
            continue
        }

        $byHost[[string]$vm.vmName] = [PSCustomObject]@{
            jdk_versions        = $jdk.ToArray()
            dotnet_sdk_versions = $sdk.ToArray()
            dotnet_tools_tools  = $tools.ToArray()
        }
    }

    return [PSCustomObject]$byHost
}

<#
.SYNOPSIS
    Normalizes one optional toolchain field on a VM object into an array of
    entry objects, absorbing the scalar-or-list and null/[]/absent shapes.

.DESCRIPTION
    The config schema lets javaDevKit / dotnetSdk arrive as a single object OR
    a one-element list, and any of the three fields may be null, [], or absent.
    This collapses all of that to a plain array the caller iterates: a scalar
    becomes a one-element array, a list stays as-is, and null/[]/absent become
    an empty array. The ,@(...) wrap preserves array shape across the return so
    a single entry does not unwrap to a scalar (the shape trap StrictMode and
    the no-bare-empty-return lint both guard).
#>
function Get-VmToolchainFieldEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Vm,
        [Parameter(Mandatory)] [string] $FieldName
    )

    $prop = $Vm.PSObject.Properties[$FieldName]
    if ($null -eq $prop -or $null -eq $prop.Value) {
        return , @()
    }
    return , @($prop.Value)
}
