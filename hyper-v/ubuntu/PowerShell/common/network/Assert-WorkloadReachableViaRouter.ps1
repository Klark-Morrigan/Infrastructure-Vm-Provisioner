<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1 alongside
    the other common/ssh helpers.
#>

# ---------------------------------------------------------------------------
# Assert-WorkloadReachableViaRouter
#   Polls a workload VM's :22 from the router (via an SSH session the
#   caller already owns), throws a directed error with router-side
#   diagnostics attached when the workload never delivers an SSH
#   banner. Used by create-vm.ps1's wait-for-SSH as a fail-fast gate
#   ahead of the 10-minute host-side polling budget.
#
#   Why a router-side gate at all:
#     SSH.NET's ForwardedPortLocal accepts the local TCP socket the
#     moment its listener binds, so host-side bare TCP probes through
#     the tunnel succeed instantly even when the router cannot
#     actually reach the workload. That false positive only resolves
#     once Test-SshBanner reads a real banner via the tunnel, which
#     can take the full wait-for-SSH budget (10 min) to time out if
#     the router-to-workload leg is broken. Probing from the router
#     directly through the jump session we already own catches the
#     break in minutes with a directed message instead of a 10-minute
#     wall of dots.
#
#   What the diagnostic bundle covers:
#     ip route, ip addr (priv0/ext0), ping, ip neigh, nc -vw3,
#     sysctl ip_forward, sudo nft list ruleset, systemd unit health.
#     One SSH round-trip; sections delimited so a quick grep -A pulls
#     the offender out. Written to <DiagFolder>\router-side-probe.log
#     alongside console.log and Invoke-CloudInitDiagnostics output.
#
#   The thrown error message includes a one-line symptom hint
#   extracted from the bundle (e.g. "Connection refused" -> sshd not
#   bound to priv0-side IP) so the operator gets actionable signal
#   before opening the file.
# ---------------------------------------------------------------------------
function Assert-WorkloadReachableViaRouter {
    [CmdletBinding()]
    param(
        # SSH.NET SshClient connected to the router. Caller owns its
        # lifetime; this helper neither opens nor disposes it.
        [Parameter(Mandatory)]
        [object] $JumpClient,

        # Workload's IPv4 on the per-environment private switch.
        [Parameter(Mandatory)]
        [string] $WorkloadIp,

        # Used in the thrown error message and the diag file location.
        [Parameter(Mandatory)]
        [string] $WorkloadVmName,

        # Used in the thrown error message.
        [Parameter(Mandatory)]
        [string] $RouterVmName,

        # Folder under which router-side-probe.log lands. Typically
        # <vmConfigPath>\diagnostics\<vmName>\<timestamp> - the same
        # path Invoke-CloudInitDiagnostics writes to. Created if
        # absent.
        [Parameter(Mandatory)]
        [string] $DiagFolder,

        [Parameter()]
        [int] $TimeoutSeconds = 300,

        [Parameter()]
        [int] $PollIntervalSeconds = 5,

        # Fired once per "no banner yet" iteration BEFORE the probe.
        # Used by Invoke-VmCreation to abort the loop when Hyper-V
        # reports the VM is no longer Running (KVP / VM-state
        # checks are caller concerns, not this helper's).
        [Parameter()]
        [scriptblock] $OnPoll
    )

    $probeStart    = Get-Date
    $bannerReached = $false
    Write-Host "  Probing $($WorkloadIp):22 from router ..." -NoNewline

    while (((Get-Date) - $probeStart).TotalSeconds -lt $TimeoutSeconds) {
        if ($null -ne $OnPoll) { & $OnPoll }

        # nc with -w 3 caps both connect and idle at 3 s. head -c 4
        # captures the first four bytes - SSH's protocol-version
        # banner always starts with "SSH-" so a match confirms the
        # workload's sshd actually replied (not a half-open TCP from
        # an SSH.NET listener that accepts before the channel opens).
        # The redirect from /dev/null EOFs nc's stdin so it returns
        # as soon as the banner arrives or the timeout expires.
        $probeCmd = "nc -w 3 $WorkloadIp 22 < /dev/null | head -c 4"
        $result   = Invoke-SshClientCommand `
                        -SshClient $JumpClient `
                        -Command   $probeCmd
        $banner   = ($result.Output -join '').Trim()
        if ($result.ExitStatus -eq 0 -and $banner.StartsWith('SSH-')) {
            $bannerReached = $true
            break
        }

        Write-Host '.' -NoNewline
        Start-Sleep -Seconds $PollIntervalSeconds
    }
    Write-Host ''

    if ($bannerReached) {
        Write-Host "  [OK] router reached workload SSH." -ForegroundColor Green
        return
    }

    # ----- Diagnostic capture --------------------------------------------
    # Bundle the router-side checks an operator would otherwise ssh in
    # to run by hand. Each command is suffixed with || true so one
    # failure (e.g. priv0 missing) does not abort the rest of the
    # bundle. CRLF normalisation below avoids the remote-bash trap
    # where a trailing \r turns `|| true` into an unknown command.
    $diagCmd = @'
echo "=== ip route ==="
ip route || true
echo "=== ip addr show priv0 ==="
ip addr show priv0 || echo "priv0 not present"
echo "=== ip addr show ext0 ==="
ip addr show ext0 || echo "ext0 not present"
echo "=== ping -c 2 -W 1 __WORKLOAD__ ==="
ping -c 2 -W 1 __WORKLOAD__ || true
echo "=== ip neigh show __WORKLOAD__ ==="
ip neigh show __WORKLOAD__ || true
echo "=== nc -vw 3 __WORKLOAD__ 22 < /dev/null ==="
nc -vw 3 __WORKLOAD__ 22 < /dev/null 2>&1 || true
echo "=== sysctl net.ipv4.ip_forward ==="
sysctl net.ipv4.ip_forward || true
echo "=== sudo nft list ruleset ==="
sudo nft list ruleset 2>&1 || true
echo "=== systemctl is-active dnsmasq nftables ==="
systemctl is-active dnsmasq nftables || true
'@
    $diagCmd = $diagCmd -replace '__WORKLOAD__', $WorkloadIp
    $diagCmd = $diagCmd -replace "`r`n", "`n"

    $diagResult = $null
    try {
        $diagResult = Invoke-SshClientCommand `
                          -SshClient $JumpClient `
                          -Command   $diagCmd
    } catch {
        Write-Warning ("Router-side diagnostic capture itself failed: " +
            "$($_.Exception.Message). Original gate failure follows.")
    }

    $diagPath = $null
    if ($null -ne $diagResult) {
        if (-not (Test-Path -Path $DiagFolder -PathType Container)) {
            New-Item -ItemType Directory -Path $DiagFolder -Force | Out-Null
        }
        $diagPath = Join-Path $DiagFolder 'router-side-probe.log'
        Set-Content -Path $diagPath -Encoding UTF8 `
                    -Value ($diagResult.Output -join "`n")
        Write-Host "  [diag] router-side probe captured to $diagPath" `
            -ForegroundColor DarkGray
    }

    # Extract the most actionable signal from the diag bundle. Order
    # matters: ping failure (layer 2/3) precedes nc failure
    # (transport/app), and ip_forward=0 is checked last because it
    # only matters once the basic-reachability checks rule out
    # everything else.
    $hint = ''
    if ($null -ne $diagResult) {
        $diagText = ($diagResult.Output -join "`n")
        if ($diagText -match '100% packet loss') {
            $hint = ' Symptom: router cannot ping the workload (100% packet loss) - layer-2 / priv0 problem.'
        }
        elseif ($diagText -match 'No route to host') {
            $hint = ' Symptom: "No route to host" - router has no priv0 / 10.99.0.0 route.'
        }
        elseif ($diagText -match 'Connection refused') {
            $hint = ' Symptom: workload "Connection refused" on :22 - sshd not bound to the priv0-side IP.'
        }
        elseif ($diagText -match 'Connection timed out') {
            $hint = ' Symptom: "Connection timed out" on :22 - workload firewall (ufw) likely blocking inbound.'
        }
        elseif ($diagText -match 'net\.ipv4\.ip_forward\s*=\s*0') {
            $hint = ' Symptom: ip_forward is 0 - router sysctl never applied.'
        }
    }
    $diagPointer = if ($diagPath) { " Diagnostics: $diagPath." } else { '' }

    throw (
        "Router '$RouterVmName' cannot reach workload '$WorkloadVmName' " +
        "at ${WorkloadIp}:22 within $TimeoutSeconds seconds.${hint}${diagPointer} " +
        "Failing fast instead of riding out the host-side " +
        "wait-for-SSH budget."
    )
}
