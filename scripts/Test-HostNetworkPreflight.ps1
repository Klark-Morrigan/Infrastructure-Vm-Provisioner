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
    [string] $SwitchName = 'ExternalSwitch-Shared'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'hyper-v\ubuntu\common\network\Assert-HostNetworkPreflight.ps1')

try {
    Assert-HostNetworkPreflight -SwitchName $SwitchName
    Write-Host ""
    Write-Host "Summary: host network preflight OK." -ForegroundColor Green
    exit 0
} catch {
    Write-Host ""
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
