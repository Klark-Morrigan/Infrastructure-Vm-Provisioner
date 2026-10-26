<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1 (as a
    pre-VM-creation gate) and by scripts\Test-HostNetworkPreflight.ps1
    (as a manual sanity check).
#>

# ---------------------------------------------------------------------------
# Assert-HostNetworkPreflight
#   Host-side checks that fail in seconds when the network is
#   obviously misconfigured, so the provisioner does not spend a 10-min
#   wait-for-SSH on a host that cannot reach its own VMs:
#
#     0. The session is elevated. Without it Get-VMSwitch returns
#        nothing and every check below misreads as "switch missing".
#     1. The named External vSwitch exists, has a recognized SwitchType.
#     2. Host vNIC (vEthernet (<switch>)) is Up and has an IPv4.
#     3. Switch-type expectations:
#          External - WARN on MAC sharing with a physical Wi-Fi NIC
#                     (expected when bridging Wi-Fi, but vulnerable to
#                      AP-side DHCP collision).
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
#     6. vEthernet network profile is Private (Internal switches only) -
#        Public blocks ICS's DNS-In rule. Delegated to
#        Test-HostNetworkProfileSetting.
#     7. The ICS DNS proxy answers on the path the VM is about to use.
#        Delegated to Test-IcsDnsProxyReachable.
#
#   Every check is a function of its own that RETURNS findings; this
#   function reads the host state once, hands each check the snapshot it
#   needs, and routes what comes back into one accumulator. That split is
#   what lets a check be tested against a state that is awkward to
#   produce - a Down vNIC, a shared MAC - without mocking Hyper-V.
#   Checks 1-5 live in checks\ beside this file; 6 and 7 live in
#   Infrastructure.Network.Windows, being host-network facts with no
#   Hyper-V or provisioner context.
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
    # Add-Finding (defined below) is an internal status/label/detail
    # reporting DSL; its calls read as a compact PASS/WARN/FAIL table.
    # Naming the three positional args at every call site would bloat
    # that table for no readability gain, so the positional-parameter
    # rule is suppressed for this function only.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPositionalParameters', '',
        Justification = 'Add-Finding is an internal 3-arg reporting DSL')]
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

        # WAN-side adapter name for Reset-IcsSharing's auto-repair
        # path (e.g. 'Wi-Fi'). When omitted, auto-repair is skipped
        # even if the DNS probe fails. The LAN-side adapter is
        # derived from $SwitchName so we don't take both.
        [string] $WanAdapterName,

        # Skip all auto-repair attempts. Profile/DNS check still
        # runs and FAILs are reported, but no Set-NetConnectionProfile
        # or Reset-IcsSharing fires. Use from Test-HostNetworkPreflight
        # when an operator wants to inspect state without mutating
        # it, or when another VM is mid-flight and an ICS toggle
        # would disrupt it.
        [switch] $NoAutoRepair
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

    # Routes what a check function returned into the accumulator. Checks emit
    # zero, one or several findings and stay silent when their precondition is
    # absent, so nulls are skipped rather than rejected.
    function Add-CheckFindings {
        param([object[]] $Finding)

        foreach ($f in $Finding) {
            if ($f) { Add-Finding $f.Status $f.Label $f.Detail }
        }
    }

    Write-Host ""
    Write-Host "--- Host network preflight: $SwitchName ---" -ForegroundColor Cyan

    # 0. Admin check. Hyper-V / Get-Net* cmdlets need admin (or
    #    Hyper-V Administrators group). Without it, Get-VMSwitch
    #    silently returns nothing, which the rest of the script
    #    would misread as "switch missing". Catching it here gives
    #    the operator an actionable error instead of a misleading
    #    one. Delegates to Test-IsCurrentSessionElevated so the
    #    elevation check sits behind one named predicate instead of a
    #    raw WindowsPrincipal call inline here.
    if (-not (Test-IsCurrentSessionElevated)) {
        Add-Finding FAIL "PowerShell session is elevated" `
            "Hyper-V and Get-Net* cmdlets need admin (or Hyper-V Administrators group). Re-run from an elevated PowerShell."
        Assert-PreflightFindings -Findings $findings -SwitchName $SwitchName
        return
    }
    Add-Finding PASS "PowerShell session is elevated" "Hyper-V cmdlets are reachable."

    # 1. Switch existence + type. Fetched once here; every check below reads
    #    this same snapshot rather than re-querying Hyper-V.
    $sw            = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
    $switchFinding = Test-VmSwitchPresent -SwitchName $SwitchName -Switch $sw
    Add-CheckFindings $switchFinding
    if ($switchFinding.Status -eq 'FAIL') {
        # No point running downstream checks - they all depend on the switch.
        Assert-PreflightFindings -Findings $findings -SwitchName $SwitchName
        return
    }

    # 2. Host vNIC up + IPv4. The address lookup is skipped when the adapter
    #    is absent - there is nothing to ask about - and the check reports the
    #    missing address either way.
    $alias    = "vEthernet ($SwitchName)"
    $vAdapter = Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue
    $vIp      = $null
    if ($vAdapter) {
        $vIp = Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 `
                                -ErrorAction SilentlyContinue |
               Select-Object -First 1
    }
    Add-CheckFindings (Test-HostVNicReady -Alias $alias -Adapter $vAdapter -IpAddress $vIp)

    # 3. Switch-type-specific MAC expectations.
    #    Get-WirelessNetAdapter (Infrastructure.Network.Windows) is the
    #    shared "which NICs are Wi-Fi" predicate, so the matcher cannot
    #    drift between here and the manual preflight wrapper's WAN
    #    auto-detect.
    Add-CheckFindings (Test-SwitchMacExpectation -Switch $sw `
                                                 -Adapter $vAdapter `
                                                 -IpAddress $vIp `
                                                 -WirelessAdapter (Get-WirelessNetAdapter))

    # 4. Connected route to vNIC's subnet via vNIC.
    Add-CheckFindings (Test-ConnectedRouteToSubnet -Alias $alias -IpAddress $vIp)

    # 5. IP collision between host vNIC and any VM on the same switch.
    Add-CheckFindings (Test-HostVmIpCollision -SwitchName $SwitchName `
                                              -Alias $alias `
                                              -IpAddress $vIp)

    # 6. Network profile (only relevant on Internal/ICS switches).
    #    Logic + auto-repair lives in Test-HostNetworkProfileSetting.ps1.
    if ($sw.SwitchType -eq 'Internal' -and $vAdapter) {
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

    Assert-PreflightFindings -Findings $findings -SwitchName $SwitchName
}
