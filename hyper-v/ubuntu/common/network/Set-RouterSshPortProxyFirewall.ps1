<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1.
#>

# ---------------------------------------------------------------------------
# Set-RouterSshPortProxyFirewall
#   Idempotent Windows Firewall companion to Set-RouterSshPortProxy.
#   Without this rule the portproxy listens on 0.0.0.0:<port> but the
#   firewall silently drops inbound TCP from WSL, yielding the
#   "Connection timed out during banner exchange" symptom Ansible
#   surfaces as UNREACHABLE.
#
#   Tight scoping: the rule applies ONLY when the inbound connection
#   arrives on a WSL vEthernet adapter (alias starts with
#   "vEthernet (WSL"). The host's WiFi, Ethernet, and ICS adapters
#   keep the OS-default deny posture - a coffee-shop WiFi cannot
#   reach the router VM through this rule.
#
#   No-op on hosts without a WSL adapter installed; the rest of the
#   provisioner stays usable on Linux/Mac developer boxes that
#   exercise these helpers via Pester.
# ---------------------------------------------------------------------------

function Set-RouterSshPortProxyFirewall {
    [CmdletBinding()]
    param(
        # Listen port the inbound rule covers. Must match the
        # Set-RouterSshPortProxy listen port - same default.
        [int] $ListenPort = 2222
    )

    # Discover the WSL vEthernet adapter (if any). Get-NetAdapter
    # returns nothing on hosts without WSL installed.
    $wslAdapter = Get-NetAdapter -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -like 'vEthernet (WSL*' } |
                  Select-Object -First 1

    if (-not $wslAdapter) {
        Write-Host "  [firewall] no vEthernet (WSL*) adapter found; skipping firewall rule (WSL probably not installed)."
        return
    }

    $ruleName = "Vm-Provisioner: WSL -> router SSH portproxy (TCP/$ListenPort)"

    $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "  [firewall] inbound rule '$ruleName' already present on '$($wslAdapter.Name)', skipping."
        return
    }

    Write-Host "  [firewall] adding inbound TCP/$ListenPort allow on '$($wslAdapter.Name)' (WSL-only scope)"
    New-NetFirewallRule `
        -DisplayName    $ruleName `
        -Direction      Inbound `
        -LocalPort      $ListenPort `
        -Protocol       TCP `
        -Action         Allow `
        -InterfaceAlias $wslAdapter.Name | Out-Null
}
