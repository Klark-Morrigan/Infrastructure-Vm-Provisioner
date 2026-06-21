<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1
    (auto-fire from create-vm.ps1's timeout paths) and by
    scripts\Get-VmRuntimeDiag.ps1 (manual entry point).
#>

# ---------------------------------------------------------------------------
# Invoke-VmRuntimeDiag
#   Captures host-side networking truth (Get-VM, Get-VMNetworkAdapter,
#   ARP cache, neighbor state, vEthernet config, relevant routes) PLUS,
#   when SSH opens, inside-VM runtime state (ip addr / route / ss /
#   networkd + cloud-init journals / nft ruleset / resolv). Triggered
#   both manually and automatically from create-vm.ps1's
#   wait-for-SSH and router-side reachability timeout paths.
#
#   Host-side capture is unconditional - it does not depend on SSH and
#   is exactly what diagnoses the failure modes that motivated this
#   helper:
#     - WiFi-on-External MAC collision (host vNIC and VM both bound
#       to the same IP)
#     - ICS-on-Internal DHCP drift (VM cycling through ICS leases on
#       every netplan reapply)
#   Both show up at a glance in Get-VMNetworkAdapter / Get-NetNeighbor
#   / arp -a side by side.
#
#   Guest-side capture is best-effort. If SSH opens it runs in full;
#   if not, the SSH open failure is logged into the same file and the
#   function returns successfully. The goal is forensic data, not a
#   throw chain - callers in the timeout paths are already on their
#   way to throwing.
#
#   Output:
#     <VmConfigPath>/diagnostics/<vmName>/<timestamp>/runtime-diag.log
#   Matches the existing console.log / cloud-init-*.txt layout from
#   Invoke-SerialConsoleCapture and Invoke-CloudInitDiagnostics, so
#   all per-run artifacts land in one folder.
#
#   Split into three functions so the host-side capture can be
#   tested in isolation (no SSH stubbing needed) and the orchestrator
#   wiring can be tested by mocking the two halves.
# ---------------------------------------------------------------------------

function Invoke-VmRuntimeDiag {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object] $Vm,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $VmConfigPath,

        [string] $Timestamp,

        # SSH open timeout - shorter than the post-provisioning default
        # because if SSH is going to work it works in seconds; the
        # timeout paths cannot afford a multi-minute extra wait.
        [TimeSpan] $SshOpenTimeout = ([TimeSpan]::FromSeconds(30))
    )

    if (-not $Timestamp) {
        $Timestamp = (Get-Date).ToString('yyyy-MM-dd_HH-mm-ss')
    }

    $diagDir = Get-VmDiagFolder -VmConfigPath $VmConfigPath `
                                -VmName       $Vm.vmName `
                                -Timestamp    $Timestamp
    if (-not (Test-Path -Path $diagDir -PathType Container)) {
        New-Item -ItemType Directory -Path $diagDir -Force | Out-Null
    }
    $logPath = Join-Path $diagDir 'runtime-diag.log'

    Write-Host "  [diag] runtime-diag.log -> $logPath"

    Get-VmRuntimeDiagHostSide -Vm $Vm -OutputPath $logPath

    # Best-effort guest capture. Open failures are recorded in the same
    # file and the function returns the diag folder regardless - timeout
    # paths need forensic data more than a clean exception chain.
    $session = $null
    try {
        $session = New-VmSshClientWithJump -Vm $Vm -Timeout $SshOpenTimeout
        Get-VmRuntimeDiagGuestSide -SshClient $session.Client `
                                   -OutputPath $logPath
    } catch {
        "" | Out-File -FilePath $logPath -Append
        "=== guest-side capture skipped ===" | Out-File -FilePath $logPath -Append
        "SSH open failed: $($_.Exception.Message)" |
            Out-File -FilePath $logPath -Append
    } finally {
        if ($null -ne $session) {
            # Best-effort cleanup: a Dispose failure must not mask the
            # original SSH error or the diag data already captured.
            try { $session.Dispose() } catch { $null = $_ }
        }
    }

    $diagDir
}

function Get-VmRuntimeDiagHostSide {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object] $Vm,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $OutputPath
    )

    $vmName = $Vm.vmName
    $banner = '=' * 60

    $banner                                                  | Out-File $OutputPath -Append
    "host-side runtime diag for '$vmName' at $(Get-Date -Format 'o')" |
                                                               Out-File $OutputPath -Append
    $banner                                                  | Out-File $OutputPath -Append

    "=== Get-VM ===" | Out-File $OutputPath -Append
    Get-VM -Name $vmName -ErrorAction SilentlyContinue |
        Format-List Name, State, Uptime, Status, CPUUsage,
                    MemoryAssigned, ProcessorCount |
        Out-File $OutputPath -Append

    "=== Get-VMNetworkAdapter ===" | Out-File $OutputPath -Append
    $vmNics = @(Get-VMNetworkAdapter -VMName $vmName -ErrorAction SilentlyContinue)
    $vmNics |
        Format-List Name, SwitchName, IPAddresses, MacAddress, Status |
        Out-File $OutputPath -Append

    # For each switch the VM is on, dump the host vNIC's IP/DNS/profile.
    # This is what reveals the WiFi-MAC-collision and ICS-drift cases:
    # the host vEthernet's IP sits next to the VM's reported IP in the
    # log and the duplicate (or drifted) value is obvious.
    #
    # Private switches do NOT get a host vNIC (that is the design).
    # Probe with Get-NetAdapter first - it returns $null silently for
    # missing interfaces. Get-NetIPConfiguration would otherwise emit
    # a non-terminating error from its inner Get-NetIPInterface call
    # that leaks to stderr even with -ErrorAction SilentlyContinue.
    $switches = @($vmNics | Select-Object -ExpandProperty SwitchName -Unique)
    foreach ($sw in $switches) {
        $alias = "vEthernet ($sw)"
        "=== host vNIC config: $alias ===" | Out-File $OutputPath -Append
        if (Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue) {
            Get-NetIPConfiguration -InterfaceAlias $alias |
                Format-List | Out-File $OutputPath -Append
        } else {
            "(no host vNIC bound - typical for Private switches)" |
                Out-File $OutputPath -Append
        }
    }

    # Walk every IPv4 the VM has held (per Hyper-V integration services)
    # and dump the host's neighbor cache for each. Incomplete/Stale entries
    # tell us the VM stopped answering ARP at those addresses (typical
    # ICS-drift symptom: old IP is Stale, new IP is Reachable). The
    # Get-VmAdapterIPv4 helper carries the StrictMode-safe IPAddresses
    # access pattern; see its docstring for the IPv4-only / property-
    # guard rationale.
    $vmIps = @(Get-VmAdapterIPv4 -Adapter $vmNics)

    if ($vmIps.Count -gt 0) {
        "=== Get-NetNeighbor for VM IPs ===" | Out-File $OutputPath -Append
        foreach ($ip in $vmIps) {
            Get-NetNeighbor -IPAddress $ip -ErrorAction SilentlyContinue |
                Format-List InterfaceAlias, IPAddress, LinkLayerAddress, State |
                Out-File $OutputPath -Append
        }

        "=== relevant routes ===" | Out-File $OutputPath -Append
        # /24-derived prefix for each IP - cheap heuristic that
        # covers the actual provisioner network shape (10.99.0.0/24,
        # 192.168.137.0/24, 192.168.5.0/24). A wrong-prefix probe
        # just yields an empty Get-NetRoute, not noise.
        $subnets = @($vmIps | ForEach-Object {
            ($_ -replace '\.\d+$', '.0') + '/24'
        } | Sort-Object -Unique)
        foreach ($subnet in $subnets) {
            "--- $subnet ---" | Out-File $OutputPath -Append
            Get-NetRoute -DestinationPrefix $subnet -ErrorAction SilentlyContinue |
                Format-Table -AutoSize | Out-File $OutputPath -Append
        }
    }

    # `arp -a` last - it dumps ALL interfaces, useful when neighbor cache
    # is empty (e.g. host hasn't tried to reach VM yet) or when entries
    # are static (ICS-injected).
    "=== arp -a ===" | Out-File $OutputPath -Append
    arp -a | Out-File $OutputPath -Append
}

function Get-VmRuntimeDiagGuestSide {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $OutputPath
    )

    "" | Out-File $OutputPath -Append
    "=== guest-side runtime diag at $(Get-Date -Format 'o') ===" |
        Out-File $OutputPath -Append

    # One block per capture. Ordered: smallest/fastest first so the
    # log front-loads the headline state, then larger journal slices
    # at the tail. Each command is wrapped in sh -c '... 2>&1' so
    # stderr is merged server-side; SSH.NET has no stream-merge option.
    # Single-quote escape is the standard '\'' dance.
    #
    # The systemd-* and cloud-init-output captures exist to surface
    # service-state failures that the assertion phase otherwise
    # discovers (the 2026-06 dnsmasq.service=inactive case is the
    # motivator). They cover ANY provisioned VM - non-router VMs
    # legitimately lack nftables/dnsmasq and `systemctl status` of
    # absent units is a clean "Unit not found" record, not an
    # exception.
    $captures = [ordered]@{
        'ip-addr'           = 'ip -4 addr show; echo; ip -6 addr show'
        'ip-route'          = 'ip route; echo; ip -6 route 2>&1'
        'ss-listen'         = 'ss -tln; echo; ss -uln'
        'resolv'            =
            'cat /etc/resolv.conf; echo "---"; ' +
            'resolvectl status 2>&1 | head -40'
        'systemd-failed'    =
            'systemctl --failed --no-pager 2>&1'
        'systemd-services'  =
            'systemctl status --no-pager ssh.service ssh.socket ' +
            'nftables.service dnsmasq.service ' +
            'systemd-networkd.service cloud-init.service 2>&1'
        'nftables'          = 'sudo nft list ruleset 2>/dev/null'
        'networkd-recent'   =
            'journalctl -u systemd-networkd --since "1 hour ago" ' +
            '--no-pager 2>&1 | grep -E "ext0|priv0|DHCP|lease|address" ' +
            '| tail -60'
        'cloud-init-recent' =
            'sudo journalctl -u cloud-init --since "1 hour ago" ' +
            '--no-pager 2>&1 | ' +
            'grep -iE "netplan|network|apply|reboot|error" | tail -60'
        'cloud-init-output' =
            'sudo tail -n 200 /var/log/cloud-init-output.log 2>&1'
    }

    foreach ($name in $captures.Keys) {
        "=== $name ===" | Out-File $OutputPath -Append
        $body = $captures[$name].Replace("'", "'\''")
        $cmd  = "sh -c '$body 2>&1'"
        $result = Invoke-SshClientCommand -SshClient $SshClient -Command $cmd
        $result.Output | Out-File $OutputPath -Append
    }
}
