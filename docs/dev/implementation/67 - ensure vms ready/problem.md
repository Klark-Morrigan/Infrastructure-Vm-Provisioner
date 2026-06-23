# Problem: Bring the Configured VM Fleet Back to SSH-Ready After a Host Reboot

## Index

- [Context](#context)
- [Solution Approach](#solution-approach)
- [What Is Changing](#what-is-changing)
  - [Shared power-on fleet helper `Invoke-VmFleetPowerOn`](#shared-power-on-fleet-helper-invoke-vmfleetpoweron)
  - [Shared reachability helper `Wait-VmSshAccessible`](#shared-reachability-helper-wait-vmsshaccessible)
  - [New entry-point script `ensure-vms-ready.ps1`](#new-entry-point-script-ensure-vms-readyps1)
  - [Router-first readiness ordering](#router-first-readiness-ordering)
  - [Per-VM failure policy](#per-vm-failure-policy)
- [Why Now](#why-now)
- [Affected Components](#affected-components)
- [Out of Scope](#out-of-scope)
- [Acceptance Criteria](#acceptance-criteria)

---

## Context

[start-vms.ps1](../../../../hyper-v/ubuntu/start-vms.ps1) reads the
`VmProvisionerConfig-<SecretSuffix>` vault entry and calls
[Start-VmIfStopped](../../../../../Infrastructure-HyperV/Infrastructure.HyperV/Public/Power/Start-VmIfStopped.ps1)
per VM. Its contract is deliberately narrow: it returns once Hyper-V
has **accepted the power-on command**, not once the guest has booted
or its `sshd` is answering. The script's own
[Out of Scope](../38%20-%20start%20vms/problem.md#out-of-scope) calls
this out: "callers who want up + reachable compose `start-vms.ps1`
followed by their own wait loop."

The driving scenario is **host-reboot recovery**. After a Windows
Update reboot or a power event, every VM on a host whose Hyper-V
`AutomaticStartAction` is intentionally off (the default for headless
workstations, to avoid surprise CPU/RAM on boot) comes back `Off` or
`Saved`. `start-vms.ps1` powers them on again, but "powered on" is not
"usable": the operator still hand-checks that each guest has finished
booting and is accepting SSH before any downstream work can run. What
is missing is a single, robust, reusable action that takes the whole
stored fleet from "host just rebooted" to "every VM ready" - finishing
only when every VM is **powered up, finished booting, and
SSH-accessible**, the state a human means by "ready". Today that wait
loop exists only inside the
provisioning path
([create-vm.ps1](../../../../hyper-v/ubuntu/up/vm/create-vm.ps1)),
welded to first-boot concerns (cloud-init, KVP IP discovery, diag
bundles, serial-console capture, phase timing). There is no reusable
"is this already-provisioned VM reachable again yet" primitive, and no
entry-point that brings the whole stored fleet to that state.

The reachability definition is not trivial because of the feature-53
NAT-router topology: workload VMs sit on a per-environment private
switch the host has **no route to**. A workload's `sshd` is reachable
only by tunnelling through its environment's router VM as an SSH jump
host (see [create-vm.ps1:276-289](../../../../hyper-v/ubuntu/up/vm/create-vm.ps1)).
That makes router VMs a hard ordering dependency: a router must itself
be SSH-ready before any of its workloads can even be probed.

The transport primitives this feature composes already ship in
`Infrastructure.HyperV` and are exercised by `create-vm.ps1` today:

- `Wait-VmSshBannerReachable` - TCP-connect plus an `SSH-` banner read
  (not a bare TCP accept) against an endpoint until a deadline, with
  an `-OnPoll` callback for progress + a caller-supplied early-exit
  check. This is the gate that defines "SSH-accessible".
- `New-VmSshTunnel` - opens a local port forward through a jump host
  (the router) to a target's `:22`, returning a localhost endpoint and
  a `.Dispose()` for teardown.
- `Get-VmKvpIpAddress` - resolves a VM's IPv4 via Hyper-V KVP for VMs
  whose address is not statically pinned.

This feature owns only the orchestration around them: read config,
power the fleet on, resolve each router, wait router-first, aggregate
results, surface failures, exit-code.

---

## Solution Approach

Per the off-the-shelf survey, no external tool fits: the readiness
definition is specific to our SecretStore config and our NAT-router
jump-host topology. General-purpose wait-for-SSH machinery (Packer /
Vagrant communicators, Ansible `wait_for_connection`) assumes flat
networking and its own VM lifecycle, and adopting it would mean
replacing the existing provisioning pipeline rather than fitting into
it. The components that *do* fit are all internal and already shipped:

| Candidate | Source / license | Fit | Verdict |
| --- | --- | --- | --- |
| In-repo reachability core in [create-vm.ps1](../../../../hyper-v/ubuntu/up/vm/create-vm.ps1) (`New-VmSshTunnel` + `Wait-VmSshBannerReachable`, router-first) | Internal, shipped | Exactly the "is the guest SSH-reachable, including workloads behind the router" logic, already battle-tested | **Reuse (extract core)** |
| [start-vms.ps1](../../../../hyper-v/ubuntu/start-vms.ps1) power-on loop + failure-aggregation/exit-code contract | Internal, shipped | The power-on half plus the per-VM failure policy this feature also needs | **Reuse (extract)** |
| [Group-VmsByEnvironment](../../../../hyper-v/ubuntu/common/config/Group-VmsByEnvironment.ps1) | Internal, shipped | Already the SSOT for "router(s) + workloads per private switch" | **Reuse as-is** |
| Packer / Vagrant communicator waits | OSS (MPL/MIT) | Wait-for-SSH exists but assumes flat networking + foreign lifecycle | Reject |
| Ansible `wait_for_connection` | OSS (GPL) | Same idea, disproportionate control-plane dependency for a power-on helper | Reject |

**Chosen direction: combine internal pieces, build no new probing.**
Extract two thin shared helpers from the existing call sites and
compose them in a new entry-point:

1. **`Invoke-VmFleetPowerOn`** - lift `start-vms.ps1`'s per-VM
   `Start-VmIfStopped` loop + failure aggregation into a dot-sourced
   helper, so power-on lives in one place. `start-vms.ps1` is
   retrofitted onto it with no operator-visible change.
2. **`Wait-VmSshAccessible`** - lift the topology-aware reachability
   *core* (tunnel-if-workload -> banner-poll -> dispose) into a
   dot-sourced helper. This becomes the single source of truth for
   "SSH-accessible". `create-vm.ps1`'s first-boot-only concerns
   (cloud-init wait, KVP discovery, diag bundle, serial console,
   phase timing) stay in `create-vm.ps1` wrapped around the helper.
3. **`ensure-vms-ready.ps1`** - the new entry-point: read config ->
   `Invoke-VmFleetPowerOn` -> `Group-VmsByEnvironment` -> per env, wait
   routers ready (direct), then wait workloads ready (via tunnel) ->
   aggregate -> exit-code.

The `Wait-VmSshAccessible` extraction is the highest-risk step because
it touches `create-vm.ps1`, the most load-bearing path in the repo;
the plan sequences it as its own bisectable commit with the existing
provisioning tests as the regression net, and scopes the extraction to
the tunnel+banner sub-block only.

---

## What Is Changing

### Shared power-on fleet helper `Invoke-VmFleetPowerOn`

New file
[hyper-v/ubuntu/common/power/Invoke-VmFleetPowerOn.ps1](../../../../hyper-v/ubuntu/common/power/Invoke-VmFleetPowerOn.ps1).
Owns the per-VM `Start-VmIfStopped` loop that
[start-vms.ps1:90-103](../../../../hyper-v/ubuntu/start-vms.ps1)
carries inline today: one `try`/`catch` per VM, successful transitions
into a `Transitions` bucket, failures into a `Failed` bucket
(`{ VmName, Reason }`), the rest of the list never stranded by one bad
VM. Returns
`{ Transitions = @(...); Failed = @(...) }` so callers own their own
summary formatting and exit-code policy.

`start-vms.ps1` is retrofitted onto this helper in the same change: it
keeps its synopsis, its summary lines, and its
`exit ($failed.Count -gt 0 ? 1 : 0)`, but the loop body becomes one
`Invoke-VmFleetPowerOn` call. No operator-visible behaviour change -
the summary text and exit-code contract are preserved byte-for-byte.
This prevents `ensure-vms-ready.ps1` from becoming a third inline copy
of the power-on loop, the same single-source-of-truth move feature 38
made for the vault bootstrap with
[Read-VmProvisionerConfig](../../../../hyper-v/ubuntu/common/config/Read-VmProvisionerConfig.ps1).

### Shared reachability helper `Wait-VmSshAccessible`

New file
[hyper-v/ubuntu/common/ssh/Wait-VmSshAccessible.ps1](../../../../hyper-v/ubuntu/common/ssh/Wait-VmSshAccessible.ps1).
The single source of truth for "is this VM SSH-accessible right now,
accounting for the router topology". Signature (sketch):

```
Wait-VmSshAccessible
    -Vm          <vm def>            # the VM to reach
    -RouterVm    <router def | $null># its env router, or $null if standalone/router itself
    -Deadline    <datetime>          # absolute deadline (caller owns the budget)
    [-PollIntervalSeconds <int>]     # default matches create-vm (10)
    [-OnPoll <scriptblock>]          # caller's per-poll hook (e.g. VM-state guard)
    [-OnTunnelOpened <scriptblock>]  # workloads only: invoked with the live
                                     #   tunnel (its .JumpClient) after the
                                     #   forward opens, before the banner poll -
                                     #   the seam create-vm uses to run its
                                     #   router-side diag gate against the tunnel
-> returns { Reachable = <bool>; ProbeIp; ProbePort; ElapsedSeconds }
```

Behaviour, lifted verbatim from the `create-vm.ps1` core:

- **Workload (RouterVm present):** open `New-VmSshTunnel` through the
  router, probe the returned localhost endpoint, dispose the tunnel in
  a `finally`.
- **Router / standalone (RouterVm `$null`):** probe `$Vm.ipAddress:22`
  directly.
- Either way the gate is `Wait-VmSshBannerReachable` against the chosen
  endpoint until `-Deadline`. The `-OnPoll` hook carries the caller's
  Hyper-V "is the VM still Running" early-exit check, exactly as
  `create-vm.ps1` does today, so that concern stays out of the generic
  waiter.

Explicitly **not** moved into this helper (they stay in
`create-vm.ps1`): cloud-init waiting, KVP IP discovery for DHCP
routers, `Assert-WorkloadReachableViaRouter`'s diag-bundle gate,
serial-console capture, and `Invoke-WithSubStepTimer`. Those are
first-boot provisioning concerns; bundling them would make a reachability
primitive know about diagnostics and timing. `create-vm.ps1` is
refactored to call `Wait-VmSshAccessible` for the tunnel+banner
sub-block while keeping those wrappers around it; the router-side diag
gate is injected through the `-OnTunnelOpened` seam so it still runs
against the helper-owned tunnel's jump client. `ensure-vms-ready.ps1`
passes no `-OnTunnelOpened`, so it stays on the lean banner-only path.

### New entry-point script `ensure-vms-ready.ps1`

New top-level script
[hyper-v/ubuntu/ensure-vms-ready.ps1](../../../../hyper-v/ubuntu/ensure-vms-ready.ps1)
alongside `provision.ps1` / `start-vms.ps1` / `deprovision.ps1`, taking
the same mandatory `-SecretSuffix` as every other entry-point:

1. Dot-source `Install-ModuleDependencies.ps1`,
   `Read-VmProvisionerConfig.ps1`, `Group-VmsByEnvironment.ps1`,
   `Invoke-VmFleetPowerOn.ps1`, `Wait-VmSshAccessible.ps1`, and the
   router-IP resolver
   [Resolve-ExistingRouterIp.ps1](../../../../hyper-v/ubuntu/common/network/Resolve-ExistingRouterIp.ps1).
2. `$vmDefs = Read-VmProvisionerConfig -SecretSuffix $SecretSuffix`.
3. `Invoke-VmFleetPowerOn -VmDefs $vmDefs` to bring every VM to
   Running. Power-on failures are recorded but do not abort the
   readiness phase for the VMs that did start.
4. `Group-VmsByEnvironment -VmDefs $vmDefs` and, per environment,
   apply [router-first readiness ordering](#router-first-readiness-ordering).
5. Print a per-VM readiness line and a final aggregate
   (`Ready: N, Unreachable: M, Power-on failed: K`), then
   `exit` non-zero if any VM is not Ready.

### Router-first readiness ordering

Within each environment returned by `Group-VmsByEnvironment`:

1. **Routers first.** For each router VM, resolve its IP if not
   statically pinned (`Resolve-ExistingRouterIp` / `Get-VmKvpIpAddress`,
   the existing-VM path `provision.ps1` step 7 uses), then
   `Wait-VmSshAccessible -Vm $router -RouterVm $null`. A router that
   never becomes ready marks **itself** Unreachable **and** short-
   circuits its workloads: they are reported `Unreachable (router not
   ready)` without wasting a tunnel attempt that cannot succeed.
2. **Workloads second.** Only once the router is ready, each workload
   gets `Wait-VmSshAccessible -Vm $workload -RouterVm $router`, which
   tunnels through the now-ready router.

This mirrors `provision.ps1`'s own router-before-workload sequencing
and the `_RouterVm` association it stamps; `ensure-vms-ready.ps1`
derives the same association from `Group-VmsByEnvironment` instead of
re-implementing it.

### Per-VM failure policy

Same philosophy as `start-vms.ps1`: one VM's failure never strands the
rest. A power-on failure, an unresolvable router IP, or a reachability
timeout is recorded against that VM and the run continues. The exit
code is the only programmatic signal - non-zero if any VM is not Ready,
zero otherwise. The script never throws past the orchestration loop.

---

## Why Now

- **Host-reboot recovery has no robust, reusable answer.** After a
  reboot, "bring the fleet up and tell me when I can actually use it"
  is the operator action that is missing. The status quo is power the
  VMs on, then hand-check each one - which scales badly past a couple
  of VMs and leaves no audit trail. Composing `start-vms` + a
  hand-rolled wait at each call site would also duplicate the
  reachability logic the provisioning path already owns.
- **Reachability has no reusable home.** The only "wait for SSH"
  implementation lives inside `create-vm.ps1`, fused to first-boot
  concerns. Any second caller (this feature, future health checks)
  would otherwise copy it and let the copies drift. Extracting it now,
  with the provisioning tests as a net, fixes that before the drift
  starts.
- **The router topology makes naive composition wrong.** A caller that
  just loops `start-vms` then probes `:22` would hang forever on
  workloads behind a router it has no route to. The correct ordering
  (router-first, tunnel-through) is non-obvious enough that it belongs
  in a reviewed, tested entry-point rather than re-derived per caller.

---

## Affected Components

- `hyper-v/ubuntu/ensure-vms-ready.ps1` (new) - the entry-point. A thin
  orchestrator: bootstrap, power-on, group, router-first wait,
  aggregate, exit-code. No business logic beyond sequencing.
- `hyper-v/ubuntu/common/power/Invoke-VmFleetPowerOn.ps1` (new) - the
  shared power-on loop extracted from `start-vms.ps1`.
- `hyper-v/ubuntu/common/ssh/Wait-VmSshAccessible.ps1` (new) - the
  shared reachability core extracted from `create-vm.ps1`.
- [hyper-v/ubuntu/start-vms.ps1](../../../../hyper-v/ubuntu/start-vms.ps1) -
  retrofit onto `Invoke-VmFleetPowerOn`. Summary text and exit-code
  contract unchanged.
- [hyper-v/ubuntu/up/vm/create-vm.ps1](../../../../hyper-v/ubuntu/up/vm/create-vm.ps1) -
  refactor the tunnel-setup + `Wait-VmSshBannerReachable` sub-block to
  call `Wait-VmSshAccessible`. Diag/timing/serial/KVP-discovery
  wrappers preserved around it. The riskiest change; its existing
  test/behaviour is the regression net.
- [hyper-v/ubuntu/Install-ModuleDependencies.ps1](../../../../hyper-v/ubuntu/Install-ModuleDependencies.ps1) -
  confirm the `Infrastructure.HyperV` `-MinimumVersion` floor ships
  `Wait-VmSshBannerReachable`, `New-VmSshTunnel`, and
  `Get-VmKvpIpAddress`. Bump only if the floor is behind; otherwise a
  no-op confirmation, same rule feature 38 step 1 followed.
- [README.md](../../../../README.md) - new `## ensure-vms-ready.ps1`
  section after `## start-vms.ps1` (lifecycle order), the readiness
  definition, the router-first note, one usage example, the per-VM
  failure policy. Index + Quick-start updated.
- `Tests/common/power/Invoke-VmFleetPowerOn.Tests.ps1` (new),
  `Tests/common/ssh/Wait-VmSshAccessible.Tests.ps1` (new),
  `Tests/ensure-vms-ready.Tests.ps1` (new), and a review of
  `Tests/start-vms.Tests.ps1` to move any power-on-loop assertions onto
  the helper's suite. Test matrices live in [plan.md](plan.md).

---

## Out of Scope

- **Authenticated login / cloud-init wait.** Readiness is defined as an
  `SSH-` banner answering, not a successful credentialed login or a
  `cloud-init status` of done. Banner reachability is the gate
  `create-vm.ps1` already trusts and needs no vault credentials at the
  probe layer beyond the router jump the tunnel already uses. A deeper
  "login works" / "cloud-init finished" check is a separable future
  flag, not bundled here.
- **A `Stop`/`shutdown` counterpart.** Bringing the fleet *down*
  gracefully is its own feature with its own state machine and
  destructive-vs-graceful policy.
- **Selecting a subset of VMs.** v1 readies every VM in the config, the
  same all-or-nothing surface `start-vms.ps1` ships. A `-VmName` filter
  is deferred until a real demand exists; the no-argument default would
  not break when it lands.
- **Parallel readiness waiting.** Routers and workloads are waited
  sequentially. Per-environment parallelism (or workload fan-out behind
  a ready router) is a latency optimisation that needs a thread-safe
  aggregator; not justified at current VM counts and would obscure the
  v1 logic.
- **Re-running provisioning.** `ensure-vms-ready.ps1` never creates,
  reconciles, or mutates a VM's disk/seed/toolchain - it only powers on
  and waits. Operators who need (re)provisioning run `provision.ps1`.
- **DHCP-router validation.** Router IP resolution reuses the existing
  `Resolve-ExistingRouterIp` / KVP path with its current limitations
  (the `externalDhcp` mode is still flagged unfinished upstream); this
  feature does not finish or revalidate that path.

---

## Acceptance Criteria

- Running `ensure-vms-ready.ps1 -SecretSuffix <s>` against a valid
  config powers on every VM, then reports each VM `Ready` only after an
  `SSH-` banner is observed on its reachable endpoint, and exits 0 when
  all VMs are Ready.
- For an environment with a router and workloads: the router is waited
  to ready **before** any workload is probed; each workload is reached
  by tunnelling through that router (no host-direct probe of a private
  IP the host cannot route to).
- A router that never becomes ready marks itself `Unreachable` and
  marks each of its workloads `Unreachable (router not ready)` without
  attempting a doomed tunnel; the run still completes and exits 1.
- A single VM failing to power on or to become reachable does not abort
  the run; remaining VMs are still processed, and the failed VM's name
  + reason appear in the output. Exit code is 1 if any VM is not Ready,
  0 otherwise. The script never throws past the loop.
- Re-running against an already-ready fleet is a no-op that still exits
  0: `Start-VmIfStopped` reports `AlreadyRunning` for each VM and every
  VM is reachable on the first poll.
- `Wait-VmSshAccessible` is the only place "SSH-accessible" is defined:
  after the refactor, `create-vm.ps1` reaches its tunnel+banner gate
  through the helper, and its existing provisioning behaviour/tests are
  unchanged.
- After the retrofit, `start-vms.ps1` produces the same summary text
  and exit-code behaviour it does today; its power-on-loop coverage now
  lives in the `Invoke-VmFleetPowerOn` suite.
- A missing/empty vault yields the same "Run setup-secrets.ps1 first"
  wording every other entry-point produces (inherited via
  `Read-VmProvisionerConfig`).
- `start-vms.ps1` remains available as the power-on-only path for
  operators who do not need the reachability wait.
- README lifecycle order reads `provision -> start-vms ->
  ensure-vms-ready -> deprovision`, and the readiness definition +
  router-first behaviour are documented.
