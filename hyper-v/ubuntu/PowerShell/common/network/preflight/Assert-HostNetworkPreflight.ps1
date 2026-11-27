<#
.NOTES
    Do not run this file directly. Dot-sourced by Import-PreflightFunctions.ps1.
#>

# ---------------------------------------------------------------------------
# Assert-HostNetworkPreflight
#   Host-side checks that fail in seconds when the network is
#   obviously misconfigured, so the provisioner does not spend a 10-min
#   wait-for-SSH on a host that cannot reach its own VMs.
#
#   Every check is a function of its own that RETURNS findings; this
#   function reads the host state once, hands each check the snapshot it
#   needs, and routes what comes back into one accumulator. That split is
#   what lets a check be tested against a state that is awkward to
#   produce - a Down vNIC, a shared MAC - without mocking Hyper-V.
#
#   What each check catches, and why, is in that check's own header. They
#   live in checks\ beside this file, except the network-profile and ICS-DNS
#   checks, which live in Infrastructure.Network.Windows, being host-network
#   facts with no Hyper-V or provisioner context. The README's
#   Test-HostNetworkPreflight.ps1 section tables them all.
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
        [string] $SwitchName,

        # ICS DNS-proxy probe target (typically the host-side ICS
        # gateway IP, e.g. 192.168.137.1 = the LAN-side vEthernet's
        # address). When set, the preflight verifies the host can
        # resolve via this IP - the same UDP/53 path the VM is
        # about to use. When omitted, the DNS-via-ICS check + its
        # auto-repair are skipped (the rest of the preflight still
        # runs).
        [string] $DnsProbeTarget,

        # WAN-side adapter name (e.g. 'Wi-Fi'): the adapter ICS shares.
        # The internet-route check compares the host's route against it,
        # and Reset-IcsSharing toggles it on the auto-repair path. When
        # omitted, that check reports itself skipped and auto-repair is
        # skipped even if the DNS probe fails. The LAN-side adapter is
        # derived from $SwitchName so we don't take both.
        [string] $WanAdapterName,

        # Skip all auto-repair attempts. Profile/DNS check still
        # runs and FAILs are reported, but no Set-NetConnectionProfile
        # or Reset-IcsSharing fires. Use from Test-HostNetworkPreflight
        # when an operator wants to inspect state without mutating
        # it, or when another VM is mid-flight and an ICS toggle
        # would disrupt it.
        [switch] $NoAutoRepair,

        # Downgrade the internet-route check's FAIL to a WARN, for a host
        # where that check is a false positive. The finding stays in the
        # report; only the block goes.
        [switch] $AllowInternetRouteFault
    )

    # Per-call verdict accumulator. Findings array drives both the
    # console output AND the throw message at the end - same source
    # for both keeps the operator-facing error in sync with the log.
    $findings = [System.Collections.Generic.List[object]]::new()

    # Prints what a check function returned and adds it to the accumulator.
    # Checks emit zero, one or several findings and stay silent when their
    # precondition is absent, so nulls are skipped rather than rejected.
    function Add-CheckFindings {
        param([object[]] $Finding)

        foreach ($f in $Finding) {

            if (-not $f) {
                continue
            }

            $color = switch ($f.Status) {
                'PASS' { 'Green' }
                'WARN' { 'Yellow' }
                'FAIL' { 'Red' }
            }

            Write-Host `
                ("  [{0}] {1}" -f $f.Status, $f.Label) `
                -ForegroundColor $color

            if ($f.Detail) {
                Write-Host `
                    "         $($f.Detail)" `
                    -ForegroundColor DarkGray
            }

            $findings.Add($f)
        }
    }

    Write-Host ""
    Write-Host `
        "--- Host network preflight: $SwitchName ---" `
        -ForegroundColor Cyan

    # 0. Elevation. A FAIL ends the preflight: without admin every check
    #    below would misread an empty answer as "switch missing".
    $elevationFinding = Test-ElevatedSession

    Add-CheckFindings $elevationFinding

    if ($elevationFinding.Status -eq 'FAIL') {

        Assert-PreflightFindings `
            -Findings $findings `
            -SwitchName $SwitchName

        return
    }

    # 1. Switch existence + type. Fetched once here; every check below reads
    #    this same snapshot rather than re-querying Hyper-V.
    $sw = Get-VMSwitch `
        -Name $SwitchName `
        -ErrorAction SilentlyContinue

    $switchFinding = Test-VmSwitchPresent `
        -SwitchName $SwitchName `
        -Switch $sw

    Add-CheckFindings $switchFinding

    if ($switchFinding.Status -eq 'FAIL') {

        # No point running downstream checks - they all depend on the switch.
        Assert-PreflightFindings `
            -Findings $findings `
            -SwitchName $SwitchName

        return
    }

    # 2. Host vNIC up + IPv4. The address lookup is skipped when the adapter
    #    is absent - there is nothing to ask about - and the check reports the
    #    missing address either way.
    $alias = "vEthernet ($SwitchName)"

    $vAdapter = Get-NetAdapter `
        -Name $alias `
        -ErrorAction SilentlyContinue

    $vIp = $null

    if ($vAdapter) {

        $vIp = Get-NetIPAddress `
            -InterfaceAlias $alias `
            -AddressFamily IPv4 `
            -ErrorAction SilentlyContinue |
            Select-Object -First 1
    }

    Add-CheckFindings (Test-HostVNicReady `
        -Alias $alias `
        -Adapter $vAdapter `
        -IpAddress $vIp)

    # 3. Switch-type-specific MAC expectations.
    #    Get-WirelessNetAdapter (Infrastructure.Network.Windows) is the
    #    shared "which NICs are Wi-Fi" predicate, so the matcher cannot
    #    drift between here and the manual preflight wrapper's WAN
    #    auto-detect.
    Add-CheckFindings (Test-SwitchMacExpectation `
        -Switch $sw `
        -Adapter $vAdapter `
        -IpAddress $vIp `
        -WirelessAdapter (Get-WirelessNetAdapter))

    # 4. Connected route to vNIC's subnet via vNIC.
    Add-CheckFindings (Test-ConnectedRouteToSubnet `
        -Alias $alias `
        -IpAddress $vIp)

    # 5. IP collision between host vNIC and any VM on the same switch.
    Add-CheckFindings (Test-HostVmIpCollision `
        -SwitchName $SwitchName `
        -Alias $alias `
        -IpAddress $vIp)

    # 6. Network profile (only relevant on Internal/ICS switches).
    #    Logic + auto-repair lives in Test-HostNetworkProfileSetting.ps1.
    if ($sw.SwitchType -eq 'Internal' `
            -and $vAdapter) {

        Add-CheckFindings (Test-HostNetworkProfileSetting `
            -InterfaceAlias $alias `
            -NoAutoRepair:$NoAutoRepair)
    }

    # 7. DNS-via-ICS reachability + one-shot auto-repair. Logic
    #    lives in Test-IcsDnsProxyReachable.ps1.
    if ($DnsProbeTarget) {

        Add-CheckFindings (Test-IcsDnsProxyReachable `
            -DnsProbeTarget $DnsProbeTarget `
            -LanAdapterName $alias `
            -WanAdapterName $WanAdapterName `
            -NoAutoRepair:$NoAutoRepair)
    }

    # 8. Internet route leaves through the ICS WAN adapter. Only ICS forwards
    #    the VMs' traffic, so an External switch has nothing to compare.
    if ($sw.SwitchType -eq 'Internal') {

        Add-CheckFindings (Test-InternetRouteThroughWan `
            -WanAdapterName $WanAdapterName `
            -InternetRoute (Get-InternetRoute) `
            -AllowInternetRouteFault:$AllowInternetRouteFault)
    }

    Assert-PreflightFindings `
        -Findings $findings `
        -SwitchName $SwitchName
}
