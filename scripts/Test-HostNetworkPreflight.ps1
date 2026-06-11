<#
.SYNOPSIS
    Manual entry point for the host-side network preflight gate that
    provision.ps1 fires automatically before VM creation. Use this to
    sanity-check the host before kicking off a provisioner run, or
    after any host networking change (switch recreate, ICS toggle,
    Wi-Fi LAN change).

.DESCRIPTION
    Thin wrapper around Assert-HostNetworkPreflight in
    hyper-v\ubuntu\common\network\. The function PASS/WARN/FAILs each
    check inline; on any FAIL it throws. This wrapper catches the
    throw and turns it into exit 1 so the script is composable with
    shell pipelines / CI.

.PARAMETER SwitchName
    External vSwitch name to inspect. Defaults to
    'ExternalSwitch-Shared' to match the provisioner's secret.json
    field; override when running against a custom-named switch.

.EXAMPLE
    .\scripts\Test-HostNetworkPreflight.ps1
#>

param(
    [string] $SwitchName     = 'ExternalSwitch-Shared',

    # ICS DNS-proxy probe target (host-side gateway IP). When set,
    # the preflight verifies the host can resolve via this IP.
    # Default matches the Internal+ICS topology's hardcoded
    # gateway address.
    [string] $DnsProbeTarget = '192.168.137.1',

    # WAN-side adapter used by Reset-IcsSharing during auto-repair.
    # Default matches the secret.json's externalAdapterName for
    # the E2E topology.
    [string] $WanAdapterName = 'Wi-Fi',

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
$net       = Join-Path $repoRoot 'hyper-v\ubuntu\common\network'
$preflight = Join-Path $net      'preflight'
$checks    = Join-Path $preflight 'checks'
. (Join-Path $net       'ics\Reset-IcsSharing.ps1')
. (Join-Path $checks    'Test-IcsDnsReachable.ps1')
. (Join-Path $checks    'Test-IsCurrentSessionElevated.ps1')
. (Join-Path $checks    'Test-HostNetworkProfileSetting.ps1')
. (Join-Path $checks    'Test-IcsDnsProxyReachable.ps1')
. (Join-Path $preflight 'Assert-PreflightFindings.ps1')
. (Join-Path $preflight 'Assert-HostNetworkPreflight.ps1')

try {
    Assert-HostNetworkPreflight `
        -SwitchName     $SwitchName `
        -DnsProbeTarget $DnsProbeTarget `
        -WanAdapterName $WanAdapterName `
        -NoAutoRepair:(-not $AutoRepair)
    Write-Host ""
    Write-Host "Summary: host network preflight OK." -ForegroundColor Green
    exit 0
} catch {
    Write-Host ""
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
