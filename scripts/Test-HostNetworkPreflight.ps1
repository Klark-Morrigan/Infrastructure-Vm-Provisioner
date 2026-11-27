<#
.SYNOPSIS
    Manual entry point for the host-side network preflight gate that
    provision.ps1 fires automatically before VM creation. Use this to
    sanity-check the host before kicking off a provisioner run, or
    after any host networking change (switch recreate, ICS toggle,
    Wi-Fi LAN change).

.DESCRIPTION
    A thin entry point: it loads the preflight functions and hands over to
    Invoke-HostNetworkPreflightCheck, which runs Assert-HostNetworkPreflight
    and turns its verdict into an exit code - 0 for a clean host, 1 for any
    FAIL - so the script is composable with shell pipelines / CI.

    Read-only by default. The WAN adapter is auto-detected on every run,
    since detecting it changes nothing. Under -AutoRepair the profile and
    ICS-DNS checks repair what they find, and after a clean run the
    controller -> router SSH relay (netsh portproxy + its firewall
    companion) is re-laid, because the ICS toggle regenerates the Internal
    vSwitch network and strands the persisted relay.

    Every default lives on Invoke-HostNetworkPreflightCheck; the parameters
    below state it.

.PARAMETER SwitchName
    External vSwitch name to inspect. Defaults to
    'ExternalSwitch-Shared' to match the provisioner's secret.json
    field; override when running against a custom-named switch.

.PARAMETER DnsProbeTarget
    Address the DNS-via-ICS check probes. Defaults to the address ICS
    gives the host; set empty to skip that check.

.PARAMETER WanAdapterName
    WAN-side (internet-facing) adapter: what the internet-route check
    compares against and what auto-repair toggles. Defaults to the
    wireless adapter that is Up; pass it to pin the name, such as on an
    Ethernet-WAN host.

.PARAMETER RouterAddress
    Router VM SSH endpoint on the Internal vSwitch, refreshed into the
    portproxy relay after an auto-repair. Defaults to the hardcoded
    Internal+ICS router static IP; set empty to skip the relay refresh.

.PARAMETER AutoRepair
    Enable the profile / ICS-DNS auto-repair and the post-repair relay
    refresh. OFF by default so the manual entry point is purely
    diagnostic.

.PARAMETER AllowInternetRouteFault
    Downgrade the internet-route check's FAIL to a WARN, for a host where
    that check is a false positive. The finding still prints.

.EXAMPLE
    .\scripts\Test-HostNetworkPreflight.ps1

.EXAMPLE
    .\scripts\Test-HostNetworkPreflight.ps1 -AutoRepair
#>

param(
    [string] $SwitchName,
    [string] $DnsProbeTarget,
    [string] $WanAdapterName,
    [string] $RouterAddress,
    [switch] $AutoRepair,
    [switch] $AllowInternetRouteFault
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot

# Reset-IcsSharing, the Ics/Profile/DNS check functions, and
# Get-WirelessNetAdapter ship in Infrastructure.Network.Windows. The
# orchestrator + its elevation/findings helpers stay local to the
# provisioner. Floor 1.5.0: this wrapper exists to hand an operator the
# next action, and below 1.5.0 the ICS-proxy verdict describes its fix in
# prose instead of shipping the commands that carry it out. Subsumes the
# 1.3.0 floor (Get-WirelessNetAdapter, used by the WAN auto-detect and the
# orchestrator's MAC checks) and matches the agent-side floor in
# Install-ModuleDependencies.ps1.
Import-Module Infrastructure.Network.Windows `
    -MinimumVersion 1.5.0 `
    -ErrorAction Stop

. (Join-Path `
    $repoRoot `
    'hyper-v\ubuntu\PowerShell\common\network\preflight\Import-PreflightFunctions.ps1')

# Only what the operator typed is passed on, so each default has one home.
exit (Invoke-HostNetworkPreflightCheck @PSBoundParameters)
