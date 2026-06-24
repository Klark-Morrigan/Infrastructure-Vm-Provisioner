<#
.NOTES
    Do not run this file directly. Dot-sourced by create-vm.ps1 and
    ensure-vms-ready.ps1.
#>

# Wait-VmSshBannerReachable is the banner-poll primitive this helper drives;
# dot-sourced here so a consumer imports this one file and gets the probe
# wired, rather than having to remember to load the banner helper alongside
# it. Its other dependencies (New-VmSshTunnel, and the banner helper's
# Test-VmSshPort / Test-SshBanner) ship in Infrastructure.HyperV, imported by
# the entry-point's Install-ModuleDependencies, so they need no dot-source.
. "$PSScriptRoot\Wait-VmSshBannerReachable.ps1"

# ---------------------------------------------------------------------------
# Wait-VmSshAccessible
#   Single source of truth for "is this VM SSH-accessible right now,
#   accounting for the NAT-router topology". Picks the right probe endpoint
#   for the VM kind, drives Wait-VmSshBannerReachable against it until the
#   caller-owned deadline, and tears down any tunnel it opened.
#
#   Topology branch:
#     - Workload (RouterVm present): the workload sits on a per-environment
#       private switch the host has no route to (feature 53), so we open a
#       New-VmSshTunnel local port forward through its router as the SSH jump
#       host and probe the loopback endpoint that emerges at the workload.
#     - Router / standalone (RouterVm $null): probe the VM's own IP on :22
#       directly - the host is on the same upstream LAN as the router.
#
#   What this helper deliberately does NOT own (stays in create-vm.ps1):
#     KVP IP discovery, cloud-init waiting, the router-side diag bundle,
#     serial-console capture, phase timing, and the router credential gate.
#     Those are first-boot provisioning concerns; folding them in would make
#     a reachability primitive know about diagnostics and timing. The two
#     seams below let create-vm inject its first-boot concerns without the
#     helper coupling to them:
#       -OnPoll          carries the caller's per-poll side-condition (the
#                        Hyper-V "is the VM still Running" early-exit), passed
#                        straight through to Wait-VmSshBannerReachable.
#       -OnTunnelOpened  workloads only: fired with the live tunnel after the
#                        forward opens and BEFORE the banner poll, so the
#                        caller can run its router-side gate against the
#                        tunnel's JumpClient. ensure-vms-ready.ps1 passes none
#                        and stays on the lean banner-only path.
#
#   Returns one PSCustomObject:
#       Reachable      : $true once an SSH- banner is observed, $false on
#                        timeout. A timeout is NOT an error here - the caller
#                        decides what a non-ready result means (create-vm
#                        throws + captures diag; ensure-vms-ready records it
#                        and moves on).
#       ProbeIp        : the endpoint actually probed (loopback for a tunnel,
#                        the VM IP for a direct probe).
#       ProbePort      : the port actually probed.
#       ElapsedSeconds : wall-clock spent in the wait, populated on both the
#                        reachable and the timeout result.
# ---------------------------------------------------------------------------
function Wait-VmSshAccessible {
    [CmdletBinding()]
    param(
        # The VM definition to reach. Its ipAddress is the tunnel target for
        # a workload, or the direct probe IP for a router / standalone VM.
        [Parameter(Mandatory)]
        [object] $Vm,

        # The VM's environment router, or $null when $Vm is itself a router
        # or a standalone (pre-feature-53) VM. Presence is what selects the
        # tunnel branch; its ipAddress/username/password are the jump creds.
        [Parameter()]
        [AllowNull()]
        [object] $RouterVm,

        # Absolute deadline. The caller owns the budget so create-vm keeps
        # its 10-minute first-boot window while ensure-vms-ready can pass a
        # shorter reboot-recovery one. Forwarded to Wait-VmSshBannerReachable.
        [Parameter(Mandatory)]
        [datetime] $Deadline,

        # Cadence between banner polls. Default matches create-vm's 10s.
        [Parameter()]
        [int] $PollIntervalSeconds = 10,

        # Per-poll side-condition hook, forwarded verbatim to
        # Wait-VmSshBannerReachable (e.g. the Hyper-V VM-state early-exit).
        [Parameter()]
        [scriptblock] $OnPoll,

        # Workload-only seam: invoked once with the live tunnel object after
        # the forward opens and before the banner poll. Ignored on the router
        # branch (no tunnel to hand it).
        [Parameter()]
        [scriptblock] $OnTunnelOpened
    )

    # Start the clock before any work so ElapsedSeconds reflects tunnel setup
    # plus the full poll, mirroring create-vm's startTime placement.
    $startTime = Get-Date

    # A router/standalone VM has $null RouterVm and takes the direct branch;
    # only a workload opens a tunnel. Disposal below keys off $tunnel being
    # non-null, so the router branch is a safe no-op.
    $tunnel    = $null
    $hasRouter = $null -ne $RouterVm
    if ($hasRouter) {
        $tunnel    = New-VmSshTunnel `
                         -TargetIp     $Vm.ipAddress `
                         -JumpHostIp   $RouterVm.ipAddress `
                         -JumpUsername $RouterVm.username `
                         -JumpPassword $RouterVm.password
        $probeIp   = $tunnel.LocalHost
        $probePort = $tunnel.LocalPort
    }
    else {
        $probeIp   = $Vm.ipAddress
        $probePort = 22
    }

    try {
        # Run the caller's tunnel-time gate (create-vm's router-side diag
        # probe) against the helper-owned tunnel before the banner poll. A
        # throw here propagates but the finally still disposes the forward.
        if ($null -ne $tunnel -and $null -ne $OnTunnelOpened) {
            & $OnTunnelOpened $tunnel
        }

        $reachable = Wait-VmSshBannerReachable `
                         -IpAddress           $probeIp `
                         -Port                $probePort `
                         -Deadline            $Deadline `
                         -PollIntervalSeconds $PollIntervalSeconds `
                         -OnPoll              $OnPoll
    }
    finally {
        # Tear the tunnel down whether the poll succeeded, timed out, or the
        # gate threw. Dispose is idempotent and only runs when a tunnel was
        # opened (router branch leaves $tunnel $null).
        if ($null -ne $tunnel) { $tunnel.Dispose() }
    }

    $elapsedSeconds = [int]([Math]::Round(
        ((Get-Date) - $startTime).TotalSeconds))

    [PSCustomObject]@{
        Reachable      = $reachable
        ProbeIp        = $probeIp
        ProbePort      = $probePort
        ElapsedSeconds = $elapsedSeconds
    }
}
