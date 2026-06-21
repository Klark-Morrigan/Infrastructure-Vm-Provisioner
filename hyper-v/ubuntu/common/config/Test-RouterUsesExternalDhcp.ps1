<#
.NOTES
    Do not run this file directly. Dot-sourced by ConvertFrom-VmConfigJson.ps1
    (the schema entry point) so every consumer of the config layer reads the
    externalDhcp default from one place.
#>

# ---------------------------------------------------------------------------
# Test-RouterUsesExternalDhcp
#   Single source of truth for a router VM's upstream (ext0) addressing
#   mode. 'externalDhcp' is optional in the schema; when absent it defaults
#   to $false (static). Static is the default because Internal+ICS - the
#   only validated host topology - keeps a fixed 192.168.137.0/24 subnet
#   across Wi-Fi roams, so a pinned ext0 is stable while ICS's own DHCP
#   allocator drifts. DHCP is opt-in for a bridged-Wi-Fi/Ethernet External
#   switch (whose LAN subnet changes per location).
#
#   Three call sites need this exact default and must not drift:
#     - Assert-RouterVmField  : gates whether the static ipAddress/gateway
#                               fields are required.
#     - Invoke-RouterSeedIsoGeneration : picks the ext0 netplan shape
#                               (minimal dhcp4 entry vs full static).
#     - Select-VmsForProvisioning : a DHCP router has no known IP, so it
#                               classifies on VM presence and skips the
#                               static-IP conflict probe.
#
#   Returns $true when ext0 is DHCP-addressed, $false when statically
#   pinned. A JSON boolean (the expected shape) arrives as a real
#   System.Boolean, so the [bool] cast is a no-op safety net. It does
#   NOT rescue a quoted "false" - [bool] of any non-empty string is
#   $true - which is exactly why Assert-RouterVmField rejects a
#   non-boolean externalDhcp at schema time. By the time validated
#   config reaches here the value is guaranteed a real boolean; the
#   cast only matters if a caller bypasses validation.
# ---------------------------------------------------------------------------
function Test-RouterUsesExternalDhcp {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [object] $Vm
    )

    if ($Vm.PSObject.Properties['externalDhcp']) {
        return [bool] $Vm.externalDhcp
    }
    return $false
}
