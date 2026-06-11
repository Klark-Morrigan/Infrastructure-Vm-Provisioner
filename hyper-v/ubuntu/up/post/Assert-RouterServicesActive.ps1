<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1.
#>

# ---------------------------------------------------------------------------
# Assert-RouterServicesActive
#   Verifies the router VM's load-bearing services are 'active' over the
#   already-open post-provisioning SSH session. Called once per router
#   VM, right after cloud-init wait + diagnostics so the failure surfaces
#   in the per-VM provisioning timer report instead of the downstream
#   E2E assertion phase.
#
#   Motivated by the 2026-06 dnsmasq.service=inactive case: the seed's
#   `systemctl enable --now dnsmasq.service` raced systemd-networkd
#   bringing priv0 up, dnsmasq's bind failed, the unit went inactive,
#   provision.ps1 reported OK (cloud-init's runcmd returned 0), and
#   the E2E assertion phase later found the dead service. The seed
#   now ships a dnsmasq.service.d/ drop-in that fixes the race; this
#   check is the belt to that suspenders so a regression (config error,
#   ordering bug, missing dependency) is caught at provision time, not
#   in the assertion phase.
#
#   Throws on first non-active unit with the failing unit name AND its
#   `systemctl status` output so the operator does not have to SSH in
#   afterwards. systemctl status's tail of the journal is enough for
#   most diagnoses (bind failures, dependency failures, exit code).
# ---------------------------------------------------------------------------

function Assert-RouterServicesActive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $VmName,

        # Service unit names to verify. Defaults to the two the router
        # seed installs and enables; callers can pass a narrower set
        # in tests or extended one if the seed grows.
        [string[]] $RequiredServices = @('nftables.service', 'dnsmasq.service')
    )

    Write-Host "  [router-check] verifying services active on $VmName ..."

    foreach ($unit in $RequiredServices) {
        # systemctl is-active prints 'active' / 'inactive' / 'failed' /
        # 'activating' / etc. and exits 0 only when active. We do not
        # gate on ExitStatus alone because future systemd versions may
        # report 'reloading' or 'activating' with exit 0 - assert on
        # the printed value directly so the contract is explicit.
        $check = Invoke-SshClientCommand -SshClient $SshClient `
            -Command "systemctl is-active $unit"
        $state = ($check.Output -join "`n").Trim()
        if ($state -eq 'active') {
            Write-Host "  [router-check] [OK] $unit is active" -ForegroundColor Green
            continue
        }

        # Pull systemctl status so the operator sees the WHY (bind
        # error, exit code, recent journal entries) in the throw
        # message itself - no separate SSH probe required.
        $status = Invoke-SshClientCommand -SshClient $SshClient `
            -Command "systemctl status --no-pager $unit 2>&1"
        $statusOut = ($status.Output -join "`n").TrimEnd()

        throw (
            "Router service '$unit' on '$VmName' is '$state' " +
            "(expected 'active'). systemctl status output:`n$statusOut"
        )
    }

    Write-Host "  [router-check] [OK] all required services active." `
        -ForegroundColor Green
}
