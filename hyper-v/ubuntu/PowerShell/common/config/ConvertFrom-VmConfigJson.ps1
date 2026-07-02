<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1 and setup-secrets.ps1 after Common.PowerShell is loaded.
#>

# Sibling validators dot-sourced here so callers of ConvertFrom-VmConfigJson
# do not need to know which individual rule files exist - this file is the
# single entry point for the config schema. Assert-VmFilesField is supplied
# by Infrastructure.HyperV (already imported by Install-ModuleDependencies)
# so the shared shape checks are not duplicated across consumers.
. "$PSScriptRoot\Test-RouterUsesExternalDhcp.ps1"
. "$PSScriptRoot\Assert-VmUsernameField.ps1"
. "$PSScriptRoot\Assert-JavaDevKitField.ps1"
. "$PSScriptRoot\Assert-DotnetSdkField.ps1"
. "$PSScriptRoot\Assert-DotnetToolsField.ps1"
. "$PSScriptRoot\Assert-RouterVmField.ps1"
. "$PSScriptRoot\Assert-WorkloadVmField.ps1"

# Allowed values for the 'kind' field. 'workload' is the default and
# carries the historical schema; 'router' selects the dual-NIC NAT/DNS
# gateway path added in feature 53.
$script:AllowedVmKinds = @('workload', 'router')

# ---------------------------------------------------------------------------
# ConvertFrom-VmConfigJson
#   Parses a VM provisioner JSON string and validates its structure.
#   Throws a descriptive error on any problem.
#
#   Outputs each validated VM definition object to the pipeline. Callers
#   must use ConvertTo-Array to collect the result as an array:
#       $vmDefs = ConvertTo-Array (ConvertFrom-VmConfigJson -Json $json)
#
#   Centralised here so the required-field list has a single source of
#   truth - update it once when the config schema changes.
# ---------------------------------------------------------------------------

function ConvertFrom-VmConfigJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Json
    )

    try {
        $parsed = $Json | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Invalid JSON: $_"
    }

    $vmDefs = ConvertTo-Array $parsed

    if ($vmDefs.Count -eq 0) {
        throw "Config must be a non-empty JSON array of VM definitions."
    }

    # Every VM definition must supply all of these fields regardless of
    # kind. This list is the authoritative shared schema -
    # setup-secrets.ps1 and provision.ps1 both rely on it via dot-source.
    #
    # 'privateSwitchName' is in the base list because both VM kinds need it:
    # router VMs attach their downstream NIC to it; workload VMs attach their
    # only NIC to it (and use the matching router VM's privateIpAddress as
    # gateway). Feature 53 step 2.
    #
    # 'ipAddress' and 'gateway' are kind-specific and live in the per-
    # kind validators (Assert-WorkloadVmField requires them;
    # Assert-RouterVmField requires them when externalDhcp is false,
    # which is the default). The router VM's upstream NIC defaults to
    # static because Internal+ICS - the only validated topology - keeps a
    # fixed subnet across Wi-Fi roams while DHCP-via-ICS drifts. DHCP is
    # an opt-in for a bridged-Wi-Fi External vSwitch (whose LAN subnet
    # changes per location). See Assert-RouterVmField's externalDhcp note
    # for the full rationale.
    #
    # 'subnetMask' stays in the base list. Workloads use it for their
    # only NIC; router VMs always use it for the priv0 (downstream) NIC
    # regardless of how ext0 is addressed. Even a DHCP-mode router VM
    # carries a static priv0 (10.10.0.1/24 etc.) so subnetMask is
    # never optional.
    #
    # 'dns' stays in the base list - on router VMs it is dnsmasq's
    # upstream forwarder (unrelated to ext0's address mode); on workload
    # VMs it is the resolver in netplan.
    $requiredFields = @(
        'vmName', 'cpuCount', 'ramGB', 'diskGB', 'ubuntuVersion',
        'username', 'password',
        'subnetMask', 'dns',
        'vmConfigPath', 'vhdPath',
        'privateSwitchName'
    )

    foreach ($vm in $vmDefs) {
        # Assert-RequiredProperties is provided by Common.PowerShell.
        Assert-RequiredProperties `
            -Object      $vm `
            -Properties  $requiredFields `
            -Context     "VM '$(if ($vm.PSObject.Properties['vmName']) { $vm.vmName } else { '(unknown)' })'"`

        # 'kind' selects the provisioning path. Validated up front so
        # later validators run against a known kind. The allow-list is
        # closed - an unknown value is a typo, not a "future kind".
        $vmName = if ($vm.PSObject.Properties['vmName']) { $vm.vmName } else { '(unknown)' }
        if ($vm.PSObject.Properties['kind']) {
            if ($vm.kind -notin $script:AllowedVmKinds) {
                throw (
                    "VM '$vmName': kind '$($vm.kind)' is not recognised. " +
                    "Allowed: $($script:AllowedVmKinds -join ', ')."
                )
            }
        }
        $kind = if ($vm.PSObject.Properties['kind']) { $vm.kind } else { 'workload' }

        # Base-field semantic check (all kinds): reject a username that
        # collides with a pre-existing Ubuntu system group, which would
        # make cloud-init's useradd abort the account and leave the VM
        # unreachable over SSH. Runs after the required-fields check so
        # 'username' is guaranteed present.
        Assert-VmUsernameField -Vm $vm

        # Optional-field validators. Each one is a no-op when its field is
        # absent and throws with a descriptive message when present-but-malformed.
        # Assert-VmFilesField and Assert-VmEnvVarsField are shared validators
        # from Infrastructure.HyperV; arguments to Assert-VmFilesField are
        # spelled out so the provisioner opts into both entry forms (single
        # { source, target } and bulk { pattern, targetDir, ... }) at the
        # call site instead of relying on the cmdlet's defaults.
        # -AllowedSubFields governs only the single form; the bulk form's
        # allow-list is fixed inside Assert-VmFilesField by contract with
        # Copy-VmFilesByPattern. Assert-VmEnvVarsField owns every rule for
        # the envVars shape - the provisioner adds no per-entry policy.
        Assert-JavaDevKitField -Vm $vm
        Assert-DotnetSdkField -Vm $vm
        # Runs after Assert-DotnetSdkField so its cross-field check
        # ("dotnetTools requires dotnetSdk") sees an already-validated
        # dotnetSdk and only fires for genuine cross-field violations
        # rather than masking a malformed SDK declaration.
        Assert-DotnetToolsField -Vm $vm
        Assert-VmFilesField `
            -Vm                $vm `
            -AllowBulkEntries `
            -AllowedSubFields  @('source', 'target') `
            -PostEntryValidator $null
        Assert-VmEnvVarsField -Vm $vm

        # Kind-specific schema rules run after the toolchain validators
        # so a router VM declaring (e.g.) javaDevKit fails the router
        # rejection rule with a clear message instead of being rejected
        # first by the javaDevKit shape check.
        if ($kind -eq 'router') {
            Assert-RouterVmField -Vm $vm
        }
        else {
            # 'workload' is the default. The validator pins ipAddress /
            # subnetMask / gateway as required - workloads must have a
            # static IP because their gateway (= router's private IP)
            # is a config-time choice no DHCP path can provide.
            Assert-WorkloadVmField -Vm $vm
        }

        # Apply defaults for optional fields. Using Add-Member rather than
        # property assignment so the field is added when absent without
        # overwriting an explicitly supplied value.
        if (-not $vm.PSObject.Properties['kind']) {
            $vm | Add-Member -MemberType NoteProperty -Name kind -Value 'workload'
        }

        # Output each validated VM object individually to the pipeline.
        # Callers collect via @(ConvertFrom-VmConfigJson ...).
        Write-Output $vm
    }
}
