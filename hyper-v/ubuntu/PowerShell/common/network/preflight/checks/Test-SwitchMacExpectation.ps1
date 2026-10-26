<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1 and by
    scripts\Test-HostNetworkPreflight.ps1.
#>

# ---------------------------------------------------------------------------
# Test-SwitchMacExpectation
#   Preflight check 3: what the vEthernet's MAC is allowed to be, which
#   depends entirely on the switch type.
#
#     Internal - the switch gives the host its own private L3 via ICS, so a
#                MAC shared with a physical Wi-Fi NIC is a stale-config smell
#                from an unfinished External -> Internal migration. Also
#                checks the host IP is ICS's hardcoded 192.168.137.1.
#     External - a shared MAC means Hyper-V is bridging to Wi-Fi by
#                MAC-translating every VM's egress to the host's Wi-Fi MAC.
#                At the AP, the host vNIC and every VM look like ONE client,
#                so DHCP hands out a single lease and they collide on it.
#                There is no "lucky AP" workaround stable enough to
#                recommend; Internal + ICS is the durable Wi-Fi answer.
#     Other    - Private switches orphan VMs from any upstream.
#
#   The shared-MAC comparison is computed once and read by both branches:
#   written out per branch it drifted into two spellings of the same test.
# ---------------------------------------------------------------------------

function Test-SwitchMacExpectation {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object] $Switch,

        # Get-NetAdapter result for the switch's vEthernet; $null when absent.
        [object] $Adapter,

        # Get-NetIPAddress result for that vEthernet; $null when it has none.
        [object] $IpAddress,

        # Physical Wi-Fi adapters from Get-WirelessNetAdapter; empty on a
        # host with no wireless NIC, which makes every MAC check moot.
        [object[]] $WirelessAdapter
    )

    # ICS hardcodes the host side of an Internal switch to this address.
    $icsHostIp = '192.168.137.1'

    # @() wraps the WHOLE expression: an if-expression's output goes through
    # the pipeline, which unrolls a one-element array back to a scalar and an
    # empty one to $null - either way .Count below would throw under StrictMode.
    $sharedMacWifi = @(
        if ($Adapter -and $WirelessAdapter) {
            $WirelessAdapter | Where-Object { $_.MacAddress -eq $Adapter.MacAddress }
        }
    )

    if ($Switch.SwitchType -eq 'Internal') {
        if ($IpAddress -and $IpAddress.IPAddress -ne $icsHostIp) {
            [PSCustomObject]@{
                Status = 'WARN'
                Label  = "ICS host IP = $icsHostIp"
                Detail = "Got $($IpAddress.IPAddress). ICS hardcodes .1; if you customized via registry that is fine, otherwise toggle ICS off+on."
            }
        } elseif ($IpAddress) {
            [PSCustomObject]@{
                Status = 'PASS'
                Label  = "ICS host IP = $icsHostIp"
                Detail = "Matches ICS default."
            }
        }

        if ($Adapter -and $WirelessAdapter) {
            if ($sharedMacWifi.Count -gt 0) {
                [PSCustomObject]@{
                    Status = 'FAIL'
                    Label  = "vEthernet MAC distinct from WiFi MAC"
                    Detail = "vEthernet MAC matches WiFi adapter '$($sharedMacWifi[0].Name)' MAC ($($Adapter.MacAddress)). Internal switches must not share MAC with a physical adapter - did you forget to recreate the switch as Internal after External -> ICS migration?"
                }
            } else {
                [PSCustomObject]@{
                    Status = 'PASS'
                    Label  = "vEthernet MAC distinct from WiFi MAC"
                    Detail = "vEthernet MAC: $($Adapter.MacAddress)"
                }
            }
        }
    } elseif ($Switch.SwitchType -eq 'External') {
        if ($sharedMacWifi.Count -gt 0) {
            [PSCustomObject]@{
                Status = 'FAIL'
                Label  = "External switch bridged to WiFi"
                Detail = "vEthernet shares MAC with WiFi adapter '$($sharedMacWifi[0].Name)'. Hyper-V External-on-WiFi MAC-translates all egress to one MAC, so the AP gives the host vNIC and every VM the same DHCP lease and they collide on the same IP. Recreate the switch as Internal + enable Windows ICS (see the README's Networking section)."
            }
        }
    } else {
        [PSCustomObject]@{
            Status = 'WARN'
            Label  = "Switch type expected External or Internal"
            Detail = "Got $($Switch.SwitchType). Private switches orphan VMs from any upstream."
        }
    }
}
