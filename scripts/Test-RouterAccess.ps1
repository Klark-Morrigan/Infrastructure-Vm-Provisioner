<#
.SYNOPSIS
    Operator entry point for checking that the controller can actually
    reach the router VM over the host SSH relay. Run it when an Ansible
    flow reports UNREACHABLE, or after any host networking change (ICS
    toggle, switch recreate, host reboot, Wi-Fi LAN change).

.DESCRIPTION
    Thin wrapper around Test-RouterSshRelay in
    Infrastructure.Network.Windows. Every flow that reaches a workload VM
    tunnels through the router as an SSH jump host, and from WSL that hop
    goes through a host-side netsh portproxy - so when the relay is dead,
    every one of those flows fails as an opaque
    "Connection timed out during banner exchange" UNREACHABLE with no
    indication of which layer broke. This script answers that in one line.

    READ-ONLY. It moves no state and repairs nothing, so it is safe to run
    at any time and against a live estate. When it reports a fault, the
    repair is `Test-HostNetworkPreflight.ps1 -AutoRepair`, which re-lays
    the relay (among other things).

    WHAT IT PROVES, AND WHAT IT DOES NOT. The probe targets the host-side
    listen endpoint rather than the router's own IP, deliberately:
    connecting straight to the router bypasses the relay and would report
    healthy while every WSL-side consumer is broken. Being host-side
    loopback it does not traverse the Windows Firewall, so it covers the
    portproxy and its forwarding but not the firewall companion - a narrow
    gap, because that rule is scoped by remote address rather than by
    interface and so has nothing volatile to go stale against.

    EXIT CODES. Three, not two, so "the relay is broken" and "I could not
    look" are never confused - they call for completely different actions:

      0  healthy
      1  the relay is BROKEN. The probe ran and reported a fault
      2  the check COULD NOT RUN - the Infrastructure.Network.Windows
         floor is not installed. Says nothing about the relay

    No automated flow gates on this today. Every Ansible flow is gated by
    Common-Ansible's own WSL-side probe
    (ops/virtual-machines/_assert-router-reachable.sh, reached via
    _run-playbook.sh -> resolve_router), which traverses the Windows
    Firewall as well and so is the stronger check where it applies. This
    script exists for the host-side cases that run no playbook: an
    operator at a prompt, and ensure-vms-ready.ps1 (which calls the
    cmdlet directly rather than this wrapper).

.PARAMETER ListenPort
    Host-side listen port of the relay. Must match what Set-RouterSshRelay
    laid; both default to 2222.

.PARAMETER TimeoutSeconds
    Budget for the TCP connect and the banner read.

.EXAMPLE
    .\scripts\Test-RouterAccess.ps1

.EXAMPLE
    .\scripts\Test-RouterAccess.ps1 -TimeoutSeconds 10
#>

[CmdletBinding()]
param(
    [int] $ListenPort     = 2222,
    [int] $TimeoutSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Floor 1.4.0: Test-RouterSshRelay lands in 1.4.0 alongside the Set/Remove
# pair it verifies.
#
# Caught rather than thrown so an absent or too-old module exits 2 (cannot
# check) instead of the 1 a bare throw would produce, which would report a
# missing dependency as a broken relay - and send an operator to repair
# host networking that was never at fault.
try {
    Import-Module Infrastructure.Network.Windows -MinimumVersion 1.4.0 -ErrorAction Stop
}
catch {
    Write-Host ""
    Write-Host "Cannot check the router SSH relay: Infrastructure.Network.Windows" `
        -ForegroundColor Yellow
    Write-Host "1.4.0 or later is not available. $($_.Exception.Message)" `
        -ForegroundColor Yellow
    Write-Host "This says nothing about the relay itself - install the module" `
        -ForegroundColor Yellow
    Write-Host "(hyper-v\ubuntu\PowerShell\Install-ModuleDependencies.ps1) and re-run." `
        -ForegroundColor Yellow
    exit 2
}

# Report the configured relay alongside the verdict. On a failure the first
# thing an operator wants is whether it is even pointed at the right router;
# on a success it names WHICH router was reached, since the probe alone only
# proves that something answered SSH.
$rules = @(Get-NetshPortProxyRules -ErrorAction SilentlyContinue |
    Where-Object { $_.ListenPort -eq $ListenPort })

if ($rules.Count -gt 0) {
    foreach ($rule in $rules) {
        Write-Host ("Relay configured: $($rule.ListenAddress):$($rule.ListenPort) " +
            "-> $($rule.ConnectAddress):$($rule.ConnectPort)") -ForegroundColor Cyan
    }
}
else {
    Write-Host "Relay configured: (no portproxy entry on port $ListenPort)" `
        -ForegroundColor Yellow
}

$result = Test-RouterSshRelay -ListenPort $ListenPort -TimeoutSeconds $TimeoutSeconds

if ($result.Ok) {
    Write-Host $result.Reason -ForegroundColor Green
    exit 0
}

Write-Host ""
Write-Host "Router SSH relay FAILED at stage '$($result.Stage)'." -ForegroundColor Red
Write-Host $result.Reason -ForegroundColor Red
Write-Host ""
Write-Host "Repair: .\scripts\Test-HostNetworkPreflight.ps1 -AutoRepair" `
    -ForegroundColor Yellow
exit 1
