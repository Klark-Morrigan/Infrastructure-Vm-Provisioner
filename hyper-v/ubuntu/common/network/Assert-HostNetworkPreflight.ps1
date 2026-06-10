<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1 (as a
    pre-VM-creation gate) and by scripts\Test-HostNetworkPreflight.ps1
    (as a manual sanity check).
#>

# ---------------------------------------------------------------------------
# Assert-HostNetworkPreflight
#   Five host-side checks that fail in seconds when the network is
#   obviously misconfigured, so the provisioner does not spend a 10-min
#   wait-for-SSH on a host that cannot reach its own VMs:
#
#     1. The named External vSwitch exists, has a recognized SwitchType.
#     2. Host vNIC (vEthernet (<switch>)) is Up and has an IPv4.
#     3. Switch-type expectations:
#          External - WARN on MAC sharing with a physical Wi-Fi NIC
#                     (expected when bridging Wi-Fi, but vulnerable to
#                      AP-side DHCP collision - see
#                      hyperv-external-switch-wifi memory).
#          Internal - FAIL on MAC sharing (Internal switches give the
#                     host its own private L3 via ICS; a shared MAC is
#                     a stale-config smell from an unfinished
#                     External -> Internal migration).
#     4. Connected route to the host vNIC's subnet via that vNIC
#        exists. Missing route = host falls back to default WiFi
#        gateway for VM-subnet traffic - the exact symptom from the
#        ICS migration session.
#     5. No IP collision between host vNIC and any VM on the same
#        switch. Smoking gun for the WiFi External-bridge MAC-sharing
#        case where DHCP gave both the same lease.
#
#   PASS / WARN do NOT abort. FAIL throws with an actionable message
#   so the operator can resolve before the next provisioner run.
#
#   Reads only - no Get-VM* / Get-Net* mutations. Safe to run at any
#   point in the host's lifetime; cheap enough to run as a gate
#   every provision invocation.
# ---------------------------------------------------------------------------

function Assert-HostNetworkPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $SwitchName
    )

    # Per-call verdict accumulator. Findings array drives both the
    # console output AND the throw message at the end - same source
    # for both keeps the operator-facing error in sync with the log.
    $findings = [System.Collections.Generic.List[object]]::new()

    function Add-Finding {
        param(
            [ValidateSet('PASS', 'WARN', 'FAIL')]
            [string] $Status,

            [string] $Label,
            [string] $Detail
        )
        $color = switch ($Status) {
            'PASS' { 'Green' }
            'WARN' { 'Yellow' }
            'FAIL' { 'Red' }
        }
        Write-Host ("  [{0}] {1}" -f $Status, $Label) -ForegroundColor $color
        if ($Detail) { Write-Host "         $Detail" -ForegroundColor DarkGray }
        $findings.Add([PSCustomObject]@{
            Status = $Status; Label = $Label; Detail = $Detail
        })
    }

    Write-Host ""
    Write-Host "--- Host network preflight: $SwitchName ---" -ForegroundColor Cyan

    # 1. Switch existence + type.
    $sw = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
    if (-not $sw) {
        Add-Finding FAIL "VMSwitch '$SwitchName' exists" `
            "Switch is missing. Expected to have been created by Ensure-ExternalSwitch."
        # No point running downstream checks - they all depend on the switch.
        Assert-PreflightFindings -Findings $findings -SwitchName $SwitchName
        return
    }
    Add-Finding PASS "VMSwitch '$SwitchName' exists" "SwitchType=$($sw.SwitchType)"

    # 2. Host vNIC up + IPv4.
    $alias    = "vEthernet ($SwitchName)"
    $vAdapter = Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue
    if (-not $vAdapter) {
        Add-Finding FAIL "Host vNIC '$alias' present" `
            "vEthernet missing. Did switch creation finish?"
    } elseif ($vAdapter.Status -ne 'Up') {
        Add-Finding FAIL "Host vNIC '$alias' status" `
            "Status=$($vAdapter.Status). Bring it Up or recreate the switch."
    } else {
        Add-Finding PASS "Host vNIC '$alias' is Up" "MAC=$($vAdapter.MacAddress)"
    }

    $vIp = $null
    if ($vAdapter) {
        $vIp = Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 `
                                -ErrorAction SilentlyContinue |
               Select-Object -First 1
    }
    if (-not $vIp) {
        Add-Finding FAIL "Host vNIC has IPv4" `
            "No IPv4 on '$alias'. ICS may have flipped off, or DHCP has not bound."
    } else {
        Add-Finding PASS "Host vNIC has IPv4" `
            "$($vIp.IPAddress)/$($vIp.PrefixLength) ($($vIp.PrefixOrigin))"
    }

    # 3. Switch-type-specific MAC expectations.
    $wifi = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceDescription -match 'Wi-?Fi|Wireless' }

    if ($sw.SwitchType -eq 'Internal') {
        if ($vIp -and $vIp.IPAddress -ne '192.168.137.1') {
            Add-Finding WARN "ICS host IP = 192.168.137.1" `
                "Got $($vIp.IPAddress). ICS hardcodes .1; if you customized via registry that is fine, otherwise toggle ICS off+on."
        } elseif ($vIp) {
            Add-Finding PASS "ICS host IP = 192.168.137.1" "Matches ICS default."
        }
        if ($vAdapter -and $wifi) {
            $matched = @($wifi | Where-Object { $_.MacAddress -eq $vAdapter.MacAddress })
            if ($matched.Count -gt 0) {
                Add-Finding FAIL "vEthernet MAC distinct from WiFi MAC" `
                    "vEthernet MAC matches WiFi adapter '$($matched[0].Name)' MAC ($($vAdapter.MacAddress)). Internal switches must not share MAC with a physical adapter - did you forget to recreate the switch as Internal after External -> ICS migration?"
            } else {
                Add-Finding PASS "vEthernet MAC distinct from WiFi MAC" `
                    "vEthernet MAC: $($vAdapter.MacAddress)"
            }
        }
    } elseif ($sw.SwitchType -eq 'External') {
        if ($vAdapter -and $wifi) {
            $sharedMacWifi = $wifi | Where-Object { $_.MacAddress -eq $vAdapter.MacAddress }
            if ($sharedMacWifi) {
                # Hyper-V External bridges to Wi-Fi by MAC-translating
                # every VM's egress to the host's WiFi MAC. At the AP,
                # the host vNIC and every VM appear as the SAME client,
                # so DHCP hands out one lease per MAC and they collide
                # on the same IP. We hit this directly during the
                # 2026-06 trip - 30 minutes wasted before we tied
                # SourceAddress=192.168.5.8 to Test-NetConnection
                # picking WiFi as the source for its own IP. There is
                # no "lucky AP" workaround stable enough to recommend.
                # Internal + ICS is the durable Wi-Fi answer.
                Add-Finding FAIL "External switch bridged to WiFi" `
                    "vEthernet shares MAC with WiFi adapter '$($sharedMacWifi.Name)'. Hyper-V External-on-WiFi MAC-translates all egress to one MAC, so the AP gives the host vNIC and every VM the same DHCP lease and they collide on the same IP. Recreate the switch as Internal + enable Windows ICS - see feedback_hyperv_internal_plus_ics memory."
            }
        }
    } else {
        Add-Finding WARN "Switch type expected External or Internal" `
            "Got $($sw.SwitchType). Private switches orphan VMs from any upstream."
    }

    # 4. Connected route to vNIC's subnet via vNIC.
    if ($vIp) {
        $subnet = ($vIp.IPAddress -replace '\.\d+$', '.0') + "/$($vIp.PrefixLength)"
        $route  = Get-NetRoute -DestinationPrefix $subnet -ErrorAction SilentlyContinue |
                  Where-Object InterfaceAlias -eq $alias
        if (-not $route) {
            Add-Finding FAIL "Connected route $subnet via $alias" `
                "Route missing. Host will route VM traffic out the wrong interface (likely WiFi default route)."
        } else {
            $first = @($route)[0]
            Add-Finding PASS "Connected route $subnet via $alias" `
                "metric $($first.RouteMetric)+$($first.InterfaceMetric)"
        }
    }

    # 5. IP collision between host vNIC and any VM on the same switch.
    if ($vIp) {
        $vmsOnSwitch = Get-VMNetworkAdapter -All -ErrorAction SilentlyContinue |
                       Where-Object SwitchName -eq $SwitchName
        $vmIps = @($vmsOnSwitch |
            ForEach-Object { $_.IPAddresses } |
            Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })

        if ($vmIps | Where-Object { $_ -eq $vIp.IPAddress }) {
            Add-Finding FAIL "No IP collision with VMs on '$SwitchName'" `
                "Host vNIC and VM(s) both report $($vIp.IPAddress). Host steals VM traffic via local routing. Run 'ipconfig /release `"$alias`"' as a stopgap; switch to ICS for the durable fix."
        } else {
            Add-Finding PASS "No IP collision with VMs on '$SwitchName'" `
                "Host: $($vIp.IPAddress); VMs ($($vmIps.Count) IPs): $(($vmIps | Sort-Object -Unique) -join ', ')"
        }
    }

    Assert-PreflightFindings -Findings $findings -SwitchName $SwitchName
}

function Assert-PreflightFindings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[object]] $Findings,

        [Parameter(Mandatory)]
        [string] $SwitchName
    )

    $fails = @($Findings | Where-Object Status -eq 'FAIL')
    if ($fails.Count -gt 0) {
        # Multi-line throw consolidates every FAIL into a single
        # operator-facing error. Each finding's Detail is the
        # "what to do" hint so the message is actionable, not just
        # a count.
        $details = ($fails | ForEach-Object {
            "    - $($_.Label): $($_.Detail)"
        }) -join "`n"
        throw (
            "Host network preflight failed for switch '$SwitchName' " +
            "($($fails.Count) FAIL):`n$details"
        )
    }
}
