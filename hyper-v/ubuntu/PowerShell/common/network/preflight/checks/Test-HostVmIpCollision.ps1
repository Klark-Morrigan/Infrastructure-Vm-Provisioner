<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1 and by
    scripts\Test-HostNetworkPreflight.ps1.
#>

# ---------------------------------------------------------------------------
# Test-HostVmIpCollision
#   Preflight check 5: no VM on the switch reports the host vNIC's own IPv4.
#   This is the smoking gun for the Wi-Fi External-bridge case - one MAC at
#   the AP means one DHCP lease shared by the host and the VMs - and it is
#   worth its own check because the consequence is silent: the host wins local
#   routing, so it answers traffic meant for the VM and every probe "succeeds"
#   against the wrong machine.
#
#   Silent when the vNIC has no IPv4: nothing can collide with an address that
#   does not exist, and check 2 already reported it.
# ---------------------------------------------------------------------------

function Test-HostVmIpCollision {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $SwitchName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Alias,

        # Get-NetIPAddress result for $Alias; $null when it has no IPv4.
        [object] $IpAddress
    )

    if (-not $IpAddress) { return }

    $vmsOnSwitch = Get-VMNetworkAdapter -All -ErrorAction SilentlyContinue |
                   Where-Object SwitchName -eq $SwitchName
    $vmIps = @(Get-VmAdapterIPv4 -Adapter $vmsOnSwitch)

    if ($vmIps | Where-Object { $_ -eq $IpAddress.IPAddress }) {
        return [PSCustomObject]@{
            Status = 'FAIL'
            Label  = "No IP collision with VMs on '$SwitchName'"
            Detail = "Host vNIC and VM(s) both report $($IpAddress.IPAddress). Host steals VM traffic via local routing. Run 'ipconfig /release `"$Alias`"' as a stopgap; switch to ICS for the durable fix."
        }
    }

    [PSCustomObject]@{
        Status = 'PASS'
        Label  = "No IP collision with VMs on '$SwitchName'"
        Detail = "Host: $($IpAddress.IPAddress); VMs ($($vmIps.Count) IPs): $(($vmIps | Sort-Object -Unique) -join ', ')"
    }
}
