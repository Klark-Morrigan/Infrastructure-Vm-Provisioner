<#
.SYNOPSIS
    Remove one or more Hyper-V Ubuntu VMs from a JSON config stored in the
    local SecretStore vault.

.DESCRIPTION
    Reads the VmProvisionerConfig secret, validates each VM definition, stops
    and removes each VM with its associated files, then per environment tears
    down the Private switch (when no VMs remain attached) and any leftover
    singleton-NAT state at the environment's gateway IP.

    Run setup-secrets.ps1 once first to populate the vault before running
    this script.

.NOTES
    REQUIREMENTS
    - Windows 11 with Hyper-V enabled.
    - Run as Administrator (Hyper-V cmdlets require elevation).
    - Microsoft.PowerShell.SecretManagement + Microsoft.PowerShell.SecretStore
      installed by setup-secrets.ps1.
    - PowerShell 7+.

    IDEMPOTENCY
    - If a VM in the config is not found in Hyper-V, its Hyper-V teardown is
      skipped and only file cleanup is attempted. Re-running after a partial
      failure retries the outstanding file deletions.
    - Per-environment network teardown is idempotent: NetNat / host vNIC IP
      / Private switch removals each silently skip when the object is
      already absent.
    - If VMs outside the config are still attached to a Private switch, that
      switch's removal is skipped to avoid cutting their connectivity.

    SECURITY
    - No secrets are passed as command-line arguments or written to disk.
      All sensitive values are read at runtime from the encrypted vault.
#>

[CmdletBinding()]
param(
    # Required. See provision.ps1 for the suffix contract.
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SecretSuffix
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\common\config\ConvertFrom-VmConfigJson.ps1"
. "$PSScriptRoot\common\config\Get-SanitizedVmDisplay.ps1"
. "$PSScriptRoot\common\config\Group-VmsByEnvironment.ps1"
. "$PSScriptRoot\common\config\Read-VmProvisionerConfig.ps1"
. "$PSScriptRoot\common\network\Remove-LegacySingletonNat.ps1"
. "$PSScriptRoot\down\vm\remove-vm.ps1"
. "$PSScriptRoot\down\network\teardown-network.ps1"

# Install / import every required module via the centralised helper, the
# same way provision.ps1 does. Teardown now consumes
# Infrastructure.Network.Windows (Remove-RouterSshRelay) in addition to
# the SecretManagement stack Read-VmProvisionerConfig needs, so the
# dependency set is ensured up front rather than left to auto-load.
. "$PSScriptRoot\Install-ModuleDependencies.ps1"

# ---------------------------------------------------------------------------
# 1. Load + parse + validate the VmProvisionerConfig secret in one call.
#    Helper owns the SecretManagement bootstrap, vault read, and schema
#    validation - keeping this script focused on the deprovisioning pipeline.
# ---------------------------------------------------------------------------

$vmDefs = Read-VmProvisionerConfig -SecretSuffix $SecretSuffix

# ---------------------------------------------------------------------------
# 2. Per-VM removal
#    Each VM is stopped and removed from Hyper-V, then its VHDX, seed ISO,
#    and config directory are deleted. If a VM is already absent from Hyper-V
#    (re-run after partial failure), only the file cleanup is attempted.
# ---------------------------------------------------------------------------

foreach ($vm in $vmDefs) {
    Invoke-VmRemoval -Vm $vm
}

# ---------------------------------------------------------------------------
# 3. Per-environment network teardown
#    Group-VmsByEnvironment yields one record per private switch in the
#    config. Within each environment the gateway IP is taken from the
#    router VM's privateIpAddress when present (the post-feature-53
#    layout); otherwise it falls back to the first workload VM's gateway
#    (covers configs that predate the router VM but still describe the
#    singleton-NAT topology).
#
#    Invoke-NetworkTeardown is idempotent and self-guards against attached
#    VMs, so it is safe to call once per environment regardless of whether
#    the switch was actually created by this tooling or by something else.
# ---------------------------------------------------------------------------

foreach ($env in (Group-VmsByEnvironment -VmDefs $vmDefs)) {
    $gatewayIp = if ($env.RouterVms.Count -gt 0) {
        $env.RouterVms[0].privateIpAddress
    }
    else {
        $env.WorkloadVms[0].gateway
    }

    # Router external IP is the host-side SSH portproxy's connect target;
    # known only for a static router (a DHCP router has no config-time
    # external IP, and a legacy / workload-only environment has no router).
    # Passed through so Invoke-NetworkTeardown removes the relay
    # symmetrically with provision's Set-RouterSshPortProxy. Empty/absent
    # leaves the portproxy step a no-op.
    $routerExternalIp = if ($env.RouterVms.Count -gt 0 -and
                            $env.RouterVms[0].PSObject.Properties['ipAddress']) {
        $env.RouterVms[0].ipAddress
    }
    else { '' }

    Invoke-NetworkTeardown -PrivateSwitchName $env.Name `
                           -GatewayIp         $gatewayIp `
                           -RouterExternalIp  $routerExternalIp
}

Write-Host ""
Write-Host "Deprovisioning complete." -ForegroundColor Green
