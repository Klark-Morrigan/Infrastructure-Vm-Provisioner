<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1 and deprovision.ps1 (which in turn make its functions
    available to setup-network.ps1 and teardown-network.ps1).
#>

# ---------------------------------------------------------------------------
# Remove-LegacySingletonNat
#   Idempotent cleanup of the singleton-NAT topology that feature 53 step 2
#   replaced: a host-level New-NetNat rule plus a host vNIC carrying the
#   environment's gateway IP. Called once per environment per provision or
#   deprovision run so a host that was originally provisioned under the
#   pre-feature-53 layout converges on the router-VM topology without
#   operator intervention - and so a re-run against a partially-migrated
#   host finishes the job.
#
#   What it removes (for a given gateway IP):
#     - Every NetNat whose InternalIPInterfaceAddressPrefix covers the IP.
#       Searched by network prefix rather than by name so a renamed
#       'VmLAN-NAT'-style rule still gets caught, and so multiple
#       overlapping rules covering the same subnet all go.
#     - Any host vNIC carrying the gateway IP. The router VM (post-feature
#       53) owns this IP on its private NIC; a host-side entry would
#       shadow the VM-side responder for host-originated traffic.
#
#   What it does NOT touch:
#     - Switches. The Private switch lifecycle belongs to the router-VM
#       loop in provision.ps1 (Initialize-PrivateSwitch) and to
#       Invoke-NetworkTeardown's attached-VMs-guarded removal.
#     - NAT rules covering other subnets. Scoping is by network prefix,
#       not name, so this function is safe to call once per environment
#       without disturbing sibling environments or unrelated host
#       services.
# ---------------------------------------------------------------------------
function Remove-LegacySingletonNat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $GatewayIp
    )

    # NetNat sweep. Get-NetNat with no -Name returns every rule, so we
    # can filter client-side by prefix. -ErrorAction SilentlyContinue
    # for the no-rules-defined case (the cmdlet errors when the table
    # is empty on some Windows builds).
    $allNats = @(Get-NetNat -ErrorAction SilentlyContinue)
    $stale   = @($allNats | Where-Object {
        Test-IpInPrefix -IpAddress $GatewayIp `
                        -Prefix    $_.InternalIPInterfaceAddressPrefix
    })

    foreach ($nat in $stale) {
        Write-Host "  Removing legacy NetNat '$($nat.Name)' ($($nat.InternalIPInterfaceAddressPrefix)) ..."
        Remove-NetNat -Name $nat.Name -Confirm:$false
        Write-Host "  [OK] NetNat removed." -ForegroundColor Green
    }
    if ($stale.Count -eq 0) {
        Write-Host "  No legacy NetNat covering $GatewayIp - skipping." `
            -ForegroundColor Green
    }

    # Host vNIC IP cleanup. A direct -IPAddress lookup is enough - we
    # do not care which adapter carries it; whichever does, the IP is
    # leftover singleton-NAT state.
    $hostIp = Get-NetIPAddress -IPAddress $GatewayIp -ErrorAction SilentlyContinue
    if ($null -ne $hostIp) {
        Write-Host "  Removing legacy host vNIC IP $GatewayIp ..."
        Remove-NetIPAddress -IPAddress $GatewayIp -Confirm:$false
        Write-Host "  [OK] Host vNIC IP removed." -ForegroundColor Green
    }
    else {
        Write-Host "  No legacy host vNIC IP at $GatewayIp - skipping." `
            -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# Test-IpInPrefix
#   Returns $true if $IpAddress falls inside the CIDR $Prefix
#   (e.g. '192.168.1.0/24'). Pure function - no Hyper-V or networking
#   cmdlets - so it is side-effect-free and safe to import into
#   any caller. Companion to Remove-LegacySingletonNat's prefix-based
#   NetNat sweep.
# ---------------------------------------------------------------------------
function Test-IpInPrefix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $IpAddress,

        [Parameter(Mandatory)]
        [string] $Prefix
    )

    $parts = $Prefix -split '/'
    if ($parts.Count -ne 2) { return $false }

    $networkBytes = [System.Net.IPAddress]::Parse($parts[0]).GetAddressBytes()
    $ipBytes      = [System.Net.IPAddress]::Parse($IpAddress).GetAddressBytes()
    $prefixLength = [int]$parts[1]

    # Compare the first $prefixLength bits of both addresses. Walk byte by
    # byte so the mask logic stays straightforward instead of converting
    # to a 32-bit integer (which would need careful endianness handling).
    $bitsRemaining = $prefixLength
    for ($i = 0; $i -lt 4; $i++) {
        if ($bitsRemaining -ge 8) {
            if ($networkBytes[$i] -ne $ipBytes[$i]) { return $false }
            $bitsRemaining -= 8
        }
        elseif ($bitsRemaining -gt 0) {
            $mask = (0xFF -shl (8 - $bitsRemaining)) -band 0xFF
            if (($networkBytes[$i] -band $mask) -ne ($ipBytes[$i] -band $mask)) {
                return $false
            }
            $bitsRemaining = 0
        }
        else {
            break
        }
    }
    return $true
}
