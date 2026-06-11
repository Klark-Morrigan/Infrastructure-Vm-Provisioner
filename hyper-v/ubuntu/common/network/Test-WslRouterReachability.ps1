<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1.
#>

# ---------------------------------------------------------------------------
# Test-WslRouterReachability
#   Runs three probes from inside the WSL distro that the Ansible
#   flow uses and writes everything to a log file:
#     1. ping  -c 3       <RouterIp>           (ICMP reachability)
#     2. nc -zv -w5       <RouterIp>      22   (TCP/22 reachability)
#     3. ssh -o BatchMode=yes -o ConnectTimeout=5
#                          <RouterIp>          (SSH banner exchange)
#
#   Why it exists: VMs are torn down on E2E failure, so a manual
#   wsl/ssh probe after the fact is impossible. The function bakes
#   the probes into the orchestration so the operator gets a
#   structured log next to console.log + runtime-diag.log instead
#   of a one-shot Ansible error that hides whether the issue is
#   the host network, the portproxy, the router, or the workload.
#
#   Returns a [PSCustomObject] with:
#     - IcmpOk      [bool]    ping succeeded
#     - TcpOk       [bool]    nc -z succeeded
#     - SshBannerOk [bool]    ssh got a banner (auth may have failed
#                              afterwards; we only care about banner)
#     - LogPath     [string]  where the per-probe transcript landed
#
#   IcmpOk is informational only - many networks block ICMP without
#   blocking TCP/22, so a ping fail is not necessarily fatal. The
#   load-bearing field is TcpOk. SshBannerOk separates "TCP open
#   but ssh not listening / wrong port" from "everything happy".
#
#   Auth is NOT exercised: BatchMode=yes prevents password prompts
#   so the probe is non-interactive and side-effect-free. A "Permission
#   denied" response counts as a successful banner exchange because
#   it means sshd is alive and talking.
# ---------------------------------------------------------------------------

function Test-WslRouterReachability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $WslDistro,

        # Address WSL probes against. Typically the host-side
        # localhost:port forwarded by Set-RouterSshPortProxy
        # (127.0.0.1:2222) rather than the router's Internal-switch
        # IP, because WSL can only reach the latter when the
        # portproxy is in place. Caller decides.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $TargetAddress,

        [int] $TargetPort = 2222,

        # Where to write the per-probe transcript. Typical pattern:
        # next to console.log + runtime-diag.log under
        # <vhdPath>\diagnostics\<routerVmName>\<timestamp>\.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $LogPath
    )

    $logDir = Split-Path -Parent $LogPath
    if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    # Pre-flight: is the distro reachable at all? An error here
    # means the operator's WslDistro field points at a name that
    # is not installed; downstream Ansible would have failed with
    # an unrelated error.
    Invoke-WslShell -Distro $WslDistro -Command 'true' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "WSL distro '$WslDistro' is not reachable (wsl -d ... returned $LASTEXITCODE). Check Get-WslDistribution / wsl --list."
    }

    $segments = New-Object System.Collections.Generic.List[string]
    $segments.Add("=== Test-WslRouterReachability ===")
    $segments.Add("Target:     ${TargetAddress}:${TargetPort}")
    $segments.Add("WSL distro: $WslDistro")
    $segments.Add("")

    # 1. ping. Informational only; ICMP block does not block TCP.
    $segments.Add("--- ping -c 3 $TargetAddress ---")
    $pingOut = Invoke-WslShell -Distro $WslDistro `
        -Command "ping -c 3 -W 2 $TargetAddress 2>&1"
    $pingOk  = $LASTEXITCODE -eq 0
    $segments.Add($pingOut)
    $segments.Add("[exit=$LASTEXITCODE, IcmpOk=$pingOk]")
    $segments.Add("")

    # 2. nc TCP/22. Load-bearing reachability check.
    $segments.Add("--- nc -zv -w5 $TargetAddress $TargetPort ---")
    $ncOut = Invoke-WslShell -Distro $WslDistro `
        -Command "nc -zv -w5 $TargetAddress $TargetPort 2>&1"
    $tcpOk = $LASTEXITCODE -eq 0
    $segments.Add($ncOut)
    $segments.Add("[exit=$LASTEXITCODE, TcpOk=$tcpOk]")
    $segments.Add("")

    # 3. ssh banner. BatchMode=yes prevents prompts; "Permission
    #    denied" counts as a successful banner exchange.
    $segments.Add("--- ssh banner probe @ $TargetAddress port $TargetPort ---")
    $sshCommand =
        "ssh -o BatchMode=yes -o ConnectTimeout=5 " +
        "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null " +
        "-p $TargetPort sshprobe@$TargetAddress true 2>&1"
    $sshOut = Invoke-WslShell -Distro $WslDistro -Command $sshCommand
    # Banner OK if ssh got far enough to print a banner-related line.
    # 'Permission denied' / 'publickey' / 'Connection closed by ...' all
    # mean banner+auth-stage was reached. 'Connection refused' /
    # 'No route to host' / 'banner exchange' / 'timed out' do NOT.
    $sshBannerOk = ($sshOut -match 'Permission denied|publickey|Connection closed by') -and
                   ($sshOut -notmatch 'Connection refused|No route to host|banner exchange|timed out')
    $segments.Add($sshOut)
    $segments.Add("[SshBannerOk=$sshBannerOk]")
    $segments.Add("")

    $segments.Add("=== summary ===")
    $segments.Add("IcmpOk=$pingOk; TcpOk=$tcpOk; SshBannerOk=$sshBannerOk")

    Set-Content -LiteralPath $LogPath -Value ($segments -join "`r`n") -Encoding UTF8

    [PSCustomObject]@{
        IcmpOk      = $pingOk
        TcpOk       = $tcpOk
        SshBannerOk = $sshBannerOk
        LogPath     = $LogPath
    }
}
