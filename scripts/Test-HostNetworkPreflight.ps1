<#
.SYNOPSIS
    Manual entry point for the host-side network preflight gate that
    provision.ps1 fires automatically before VM creation. Use this to
    sanity-check the host before kicking off a provisioner run, or
    after any host networking change (switch recreate, ICS toggle,
    Wi-Fi LAN change).

.DESCRIPTION
    Wrapper around Assert-HostNetworkPreflight in
    hyper-v\ubuntu\PowerShell\common\network\. The function PASS/WARN/FAILs each
    check inline; on any FAIL it throws. This wrapper catches the
    throw and turns it into exit 1 so the script is composable with
    shell pipelines / CI.

    Read-only by default. Under -AutoRepair it additionally (a) auto-
    detects the WAN adapter Reset-IcsSharing toggles, and (b) after a
    successful repair re-establishes the controller -> router SSH relay
    (netsh portproxy + its firewall companion), because the ICS toggle
    regenerates the Internal vSwitch network and strands the persisted
    relay. Both repair extras run only with -AutoRepair.

.PARAMETER SwitchName
    External vSwitch name to inspect. Defaults to
    'ExternalSwitch-Shared' to match the provisioner's secret.json
    field; override when running against a custom-named switch.

.PARAMETER RouterAddress
    Router VM SSH endpoint on the Internal vSwitch, refreshed into the
    portproxy relay after an auto-repair. Defaults to the hardcoded
    Internal+ICS router static IP; set empty to skip the relay refresh.

.PARAMETER AutoRepair
    Enable the profile / ICS-DNS auto-repair and the post-repair relay
    refresh. OFF by default so the manual entry point is purely
    diagnostic.

.EXAMPLE
    .\scripts\Test-HostNetworkPreflight.ps1

.EXAMPLE
    .\scripts\Test-HostNetworkPreflight.ps1 -AutoRepair
#>

param(
    [string] $SwitchName     = 'ExternalSwitch-Shared',

    # ICS DNS-proxy probe target (host-side gateway IP). When set,
    # the preflight verifies the host can resolve via this IP.
    # Default matches the Internal+ICS topology's hardcoded
    # gateway address.
    [string] $DnsProbeTarget = '192.168.137.1',

    # WAN-side (internet-facing) adapter Reset-IcsSharing toggles during
    # auto-repair. Left empty by default and resolved at runtime from the
    # live wireless adapter (see the detection block below), because the
    # connection name varies by host ('Wi-Fi', 'Wi-Fi 2', a vendor name)
    # and a wrong name makes the COM toggle fail with "interface not
    # found". Pass explicitly to pin it (e.g. an Ethernet-WAN host).
    [string] $WanAdapterName,

    # Router VM's SSH endpoint on the Internal vSwitch. Under -AutoRepair
    # the ICS toggle regenerates the 192.168.137.0/24 network, which
    # strands the persisted netsh portproxy relay (host :2222 -> router
    # :22): iphlpsvc keeps the forwarding bound to the pre-toggle network
    # generation, so the controller (WSL) reaches the host listener but the
    # onward hop to the router never delivers. We therefore re-establish
    # that relay after a repair. Default matches the Internal+ICS topology's
    # hardcoded router static IP; set empty to skip the relay refresh (a
    # host with no router VM).
    [string] $RouterAddress  = '192.168.137.11',

    # Opt INTO auto-repair. Default OFF for the manual entry point
    # because an interactive operator running this script may have
    # other VMs alive that would lose their default route during
    # an ICS toggle. The provisioner gate calls Assert-HostNetworkPreflight
    # directly with auto-repair ON because it runs pre-VM-creation
    # when no VMs are alive.
    [switch] $AutoRepair
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$net       = Join-Path $repoRoot 'hyper-v\ubuntu\PowerShell\common\network'
$preflight = Join-Path $net      'preflight'
$checks    = Join-Path $preflight 'checks'
# Reset-IcsSharing, the Ics/Profile/DNS check functions, and
# Get-WirelessNetAdapter ship in Infrastructure.Network.Windows. The
# orchestrator + its elevation/findings helpers stay local to the
# provisioner. Floor 1.3.0: Get-WirelessNetAdapter (used by the WAN
# auto-detect below and the orchestrator's MAC checks) lands in 1.3.0.
Import-Module Infrastructure.Network.Windows -MinimumVersion 1.3.0 -ErrorAction Stop
. (Join-Path $checks    'Test-IsCurrentSessionElevated.ps1')
. (Join-Path $preflight 'Assert-PreflightFindings.ps1')
# Get-VmAdapterIPv4 backs the orchestrator's IP-collision check (check 5).
# provision.ps1 dot-sources it before Assert-HostNetworkPreflight; this
# manual wrapper must too, or the preflight dies with "Get-VmAdapterIPv4
# is not recognized" before reaching the DNS-via-ICS check.
. (Join-Path $net       'Get-VmAdapterIPv4.ps1')
# Set-RouterSshRelay (post-repair portproxy + firewall pair) and
# Get-WirelessNetAdapter (WAN auto-detect below) both come from the
# module imported above, so no dot-source for them here.
. (Join-Path $preflight 'Assert-HostNetworkPreflight.ps1')

# Resolve the WAN adapter name for auto-repair when the operator did not
# pin one. Reset-IcsSharing matches HNetCfg on the connection name, which
# is the same friendly name Get-NetAdapter reports - so detect the Up
# wireless adapter and use its name, surfacing what was found (and the
# candidate list when none) instead of failing deep in the COM call with a
# bare "interface not found - run Get-NetAdapter to confirm the name".
# Only needed under -AutoRepair: the read-only path never toggles ICS.
if ($AutoRepair -and -not $WanAdapterName) {
    $wifiAdapter = Get-WirelessNetAdapter |
        Where-Object { $_.Status -eq 'Up' } |
        Select-Object -First 1
    if ($wifiAdapter) {
        $WanAdapterName = $wifiAdapter.Name
        Write-Host ("WAN adapter auto-detected for ICS repair: '$WanAdapterName' " +
            "($($wifiAdapter.InterfaceDescription)).") -ForegroundColor Cyan
    }
    else {
        $physical = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
            Sort-Object Name |
            ForEach-Object { "$($_.Name) [$($_.Status)]" }
        Write-Host "Could not auto-detect an Up wireless adapter for ICS repair." `
            -ForegroundColor Yellow
        Write-Host "Physical adapters present: $($physical -join ', ')" `
            -ForegroundColor Yellow
        Write-Host "Re-run with -WanAdapterName '<your internet-facing connection>'." `
            -ForegroundColor Yellow
    }
}

try {
    Assert-HostNetworkPreflight `
        -SwitchName     $SwitchName `
        -DnsProbeTarget $DnsProbeTarget `
        -WanAdapterName $WanAdapterName `
        -NoAutoRepair:(-not $AutoRepair)

    # Re-establish the controller -> router SSH relay after an auto-repair.
    # The ICS toggle above regenerates the Internal vSwitch network, which
    # leaves the persisted portproxy forwarding bound to the old generation
    # (controller reaches the host listener, the onward hop to the router
    # dies). Set-RouterSshRelay re-lays the same portproxy + firewall pair
    # provision.ps1 uses, so the ops flows (runner-status / register) that
    # reach the router over WSL survive the repair. It is an idempotent
    # delete+re-add, so running it when no toggle fired is harmless.
    # Skipped when no router address is configured.
    if ($AutoRepair -and $RouterAddress) {
        Write-Host ""
        Write-Host ("Refreshing controller -> router SSH relay (-> ${RouterAddress}:22) " +
            "after host-network repair ...") -ForegroundColor Cyan
        Set-RouterSshRelay -ConnectAddress $RouterAddress
    }

    Write-Host ""
    Write-Host "Summary: host network preflight OK." -ForegroundColor Green
    exit 0
} catch {
    Write-Host ""
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
