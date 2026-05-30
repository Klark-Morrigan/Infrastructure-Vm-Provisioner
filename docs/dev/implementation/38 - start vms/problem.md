# Problem: Start All Provisioned VMs from the Stored Config

## Index

- [Context](#context)
- [What Is Changing](#what-is-changing)
  - [Shared bootstrap helper `Read-VmProvisionerConfig`](#shared-bootstrap-helper-read-vmprovisionerconfig)
  - [New entry-point script `start-vms.ps1`](#new-entry-point-script-start-vmsps1)
  - [Per-VM failure policy](#per-vm-failure-policy)
- [Why Now](#why-now)
- [Affected Components](#affected-components)
- [Out of Scope](#out-of-scope)
- [Acceptance Criteria](#acceptance-criteria)

---

## Context

`provision.ps1` reads `VmProvisionerConfig` from the local SecretStore
vault, validates the VM definitions via
[ConvertFrom-VmConfigJson.ps1](../../../../hyper-v/ubuntu/common/config/ConvertFrom-VmConfigJson.ps1),
then creates / reconciles each VM. The same vault entry is read by
`deprovision.ps1` for the inverse path. There is no equivalent
entry-point for the lifecycle event between create and delete:
**bring an already-provisioned VM back to Running** after a host
reboot, a manual shutdown, or a Hyper-V "saved" state caused by a host
power event.

`Infrastructure.HyperV` `v0.8.0` adds the transport this feature
consumes:

- [Start-VmIfStopped](../../../../../Infrastructure-HyperV/Infrastructure.HyperV/Public/Power/Start-VmIfStopped.ps1) -
  per-VM idempotent power-on. Starts an `Off` VM, resumes a `Saved`
  VM, no-ops on `Running`, and throws (without calling `Start-VM`) on
  transient states (`Paused`, `Stopping`, `Starting`, `Saving`) or any
  unrecognised state. Returns
  `{ VmName, EntryState, Action }` so callers can log the transition
  without re-querying Hyper-V.

The library function pins down the per-VM contract; this feature owns
only the orchestration around it (read config, iterate, aggregate
results, surface failures).

---

## What Is Changing

### Shared bootstrap helper `Read-VmProvisionerConfig`

`provision.ps1` and `deprovision.ps1` today carry ~25 lines of
identical bootstrap (SecretManagement provider-module import + vault
existence check + `Get-Secret` + `ConvertFrom-VmConfigJson` + the
"[OK] Config validated" line). Landing `start-vms.ps1` without
addressing this would make it a third copy and lock the divergence in;
the right move per
[CLAUDE.md - Other rules](../../../../../../../Users/Klark%20Morgan/.claude/CLAUDE.md)
("Prefer single sources of truth over duplication. Prefer minimal
diffs over large refactors.") is to extract the helper now, while
there are only two callers to retrofit.

New file
[hyper-v/ubuntu/common/config/Read-VmProvisionerConfig.ps1](../../../../hyper-v/ubuntu/common/config/Read-VmProvisionerConfig.ps1)
sits next to `ConvertFrom-VmConfigJson.ps1` and owns the full
"bootstrap -> validated VM list" path:

1. Import the two SecretManagement provider modules
   (`Microsoft.PowerShell.SecretManagement`,
   `Microsoft.PowerShell.SecretStore`) with the existing "Run
   setup-secrets.ps1 first" wording verbatim, so the operator-facing
   error message does not regress.
2. Check that the `VmProvisioner` vault exists and read
   `VmProvisionerConfig` as plaintext.
3. Dispatch the JSON to `ConvertFrom-VmConfigJson`, collect via
   `ConvertTo-Array`, and write the "[OK] Config validated" line.
4. Return the validated `$vmDefs` array.

`provision.ps1` and `deprovision.ps1` are retrofitted onto this helper
in the same change. Both lose their per-script copies of the three
steps above and replace them with a single
`$vmDefs = Read-VmProvisionerConfig` line. No operator-visible
behaviour change in either script: the helper's emitted text and
exception messages are byte-for-byte the ones the scripts produced
inline. Migration to
[Get-InfrastructureSecret](../../../../../Infrastructure-Secrets/Infrastructure.Secrets/Public/Get-InfrastructureSecret.ps1)
/ `Use-MicrosoftPowerShellSecretStoreProvider` (which would let the
helper drop the direct `Get-SecretVault` / `Get-Secret` calls) is a
separate concern - see [Out of Scope](#out-of-scope).

### New entry-point script `start-vms.ps1`

A new top-level script at
[hyper-v/ubuntu/start-vms.ps1](../../../../hyper-v/ubuntu/start-vms.ps1)
that sits alongside `provision.ps1` and `deprovision.ps1` and reuses
their (now shared) bootstrap:

1. Dot-source `Install-ModuleDependencies.ps1` to get
   `PowerShell.Common` + `Infrastructure.HyperV` + the SecretStore
   provider modules in scope.
2. Dot-source
   [Read-VmProvisionerConfig.ps1](../../../../hyper-v/ubuntu/common/config/Read-VmProvisionerConfig.ps1)
   and call `$vmDefs = Read-VmProvisionerConfig`. The helper owns
   provider import + vault read + schema validation (including
   `Assert-VmEnvVarsField` / files validation, which runs even though
   this script does not exercise those fields - validation is cheap
   and a bad config should fail loud here too).
3. Iterate the validated VM definitions and call
   `Start-VmIfStopped -VmName $vm.vmName` for each, capturing the
   returned transition object per VM.
4. Print a one-line summary per VM
   (`<vmName>: <EntryState> -> <Action>`) and a final aggregate line
   (`Started: N, Resumed: M, Already running: K, Failed: F`).
5. Exit non-zero if any VM failed; zero otherwise.

This script does **not** open an SSH session, does **not** wait for
SSH readiness, and does **not** touch the file server. Power-on is a
distinct concern from post-provisioning - callers who want
"up + reachable" compose `start-vms.ps1` followed by their own
`Wait-VmSshReady` loop, same way they can today compose `provision.ps1`
with downstream tooling.

### Per-VM failure policy

A single bad VM (unknown to Hyper-V, in `Paused`, or an unrecognised
state) must not strand the rest of the list. The script catches
exceptions from `Start-VmIfStopped` per VM, records them in a
`Failed` bucket with the original message, and continues to the next
VM. After the loop:

- If `Failed` is empty: exit 0.
- If `Failed` is non-empty: print each failed VM's name + reason on
  its own line, then exit 1.

Reason: this matches `provision.ps1`'s behaviour around per-VM
idempotency skips (an already-existing VM does not abort the run for
the others). Aborting on the first failure would punish operators who
have one VM legitimately in `Saving` (mid-checkpoint) while a host
reboot needs the other four back up immediately.

---

## Why Now

- **HyperV `v0.8.0` shipped `Start-VmIfStopped`** - the per-VM
  primitive this feature consumes. Without it the script would have
  to reinvent the state machine
  (`Off`/`Saved`/`Running`/transient/unknown) inline, and a second
  implementation would inevitably drift from the unit-tested one
  upstream.
- **Host-reboot recovery is a real gap.** After Windows Update reboots
  or a power event, VMs configured without auto-start sit in `Off` or
  `Saved`. The operator workflow today is "open Hyper-V Manager and
  click Start on each one" or hand-type `Start-VM` for every name -
  both of which scale badly past two VMs and have no audit trail.
- **The config already names every VM.** `VmProvisionerConfig` is the
  authoritative list of "VMs this repo cares about". A start-all
  script that reads any other source would invent a second source of
  truth.

---

## Affected Components

- `hyper-v/ubuntu/start-vms.ps1` (new) - the entry-point script
  described above. Sized to match `provision.ps1`'s shape: a thin
  orchestrator over dot-sourced helpers and library cmdlets, with no
  business logic of its own beyond the iteration + failure-aggregation.
- `hyper-v/ubuntu/common/config/Read-VmProvisionerConfig.ps1` (new) -
  the shared bootstrap helper described in
  [Shared bootstrap helper](#shared-bootstrap-helper-read-vmprovisionerconfig).
  Lives alongside `ConvertFrom-VmConfigJson.ps1` so both pieces of
  the "vault -> validated VMs" path sit in one folder.
- [hyper-v/ubuntu/provision.ps1](../../../../hyper-v/ubuntu/provision.ps1) -
  retrofit onto `Read-VmProvisionerConfig`. Drops the
  SecretManagement-import block, the vault-existence check, the
  `Get-Secret` call, and the `ConvertFrom-VmConfigJson` /
  "[OK] Config validated" lines in favour of one helper call.
  Operator-visible output and error wording stay byte-for-byte
  identical.
- [hyper-v/ubuntu/deprovision.ps1](../../../../hyper-v/ubuntu/deprovision.ps1) -
  same retrofit. Identical-text guarantee per the helper's contract
  ensures the deprovisioning UX is unchanged.
- [hyper-v/ubuntu/Install-ModuleDependencies.ps1](../../../../hyper-v/ubuntu/Install-ModuleDependencies.ps1) -
  bump the `Invoke-ModuleInstall -ModuleName 'Infrastructure.HyperV'`
  `-MinimumVersion` floor to `0.8.0` (the version that ships
  `Start-VmIfStopped`). Same "raise the floor to the latest required
  feature" rule that
  [34 - ci jars Step 1](../34%20-%20ci%20jars/plan.md#step-1---bump-infrastructurehyperv-dependency-to-the-latest)
  and [21 - env vars Step 1](../21%20-%20env%20vars/plan.md#step-1---confirm-infrastructurehyperv-dependency-floor)
  established. If the floor has already advanced past `0.8.0` by the
  time this lands, the bump is a no-op confirmation commit.
- [README.md](../../../../README.md) - new "Starting VMs" section
  between `provision.ps1` and `deprovision.ps1` (lifecycle order), one
  short usage example, and a sentence each on the idempotency
  contract and the per-VM failure policy. Update the Index
  accordingly.
- `Tests/common/config/Read-VmProvisionerConfig.Tests.ps1` (new) -
  unit tests for the shared bootstrap: missing provider modules
  yield the "Run setup-secrets.ps1 first" wording; missing vault
  yields the same; `Get-Secret` is invoked with the documented
  vault / secret name pair; the returned value is what
  `ConvertFrom-VmConfigJson` produced. `ConvertFrom-VmConfigJson`'s
  own behaviour is already covered by
  [Tests/common/config/](../../../../Tests/common/config) and is
  not retested here.
- `Tests/start-vms.Tests.ps1` (new) - unit tests for the start-vms
  orchestration logic (iteration + failure aggregation + exit code).
  `Read-VmProvisionerConfig` is mocked at the call site so this
  suite does not duplicate the helper's coverage. The per-VM state
  machine is covered by `Infrastructure.HyperV`'s
  [Start-VmIfStopped.Tests.ps1](../../../../../Infrastructure-HyperV/Tests/Start-VmIfStopped.Tests.ps1)
  and is not retested here.
- [Tests/provision.Tests.ps1](../../../../Tests/provision.Tests.ps1) -
  the existing suite is reviewed for any assertions that hard-code
  the inline bootstrap (e.g. spying on `Get-SecretVault` directly).
  Such assertions move to the new `Read-VmProvisionerConfig` suite;
  provision.Tests.ps1 mocks the helper instead. Same treatment for
  any equivalent deprovision tests if/when they land.

---

## Out of Scope

- **Wait-for-SSH after power-on.** Callers compose the SSH wait
  themselves via `Wait-VmSshReady` if they need "up and reachable".
  Bundling it here would force every operator to pay the wait cost
  even when "did Hyper-V accept my start command" is the only signal
  they need (e.g. a manual recovery where the operator is about to
  RDP, not SSH).
- **Auto-start on host boot.** Hyper-V already has a native
  per-VM `AutomaticStartAction` setting. This feature is the manual
  / operator-triggered equivalent for hosts where auto-start is
  intentionally off (default for headless workstations to avoid
  surprise CPU/RAM consumption on boot).
- **`Stop-VmsIfRunning` (the inverse).** A clean shutdown counterpart
  is a separate feature with its own state machine
  (`Running` -> `Stop-VM`, `Saved` -> already off, etc.) and its own
  destructive-vs-graceful policy decisions. Worth doing, not bundled
  here to keep the diff focused.
- **Selecting a subset of VMs.** v1 starts every VM in the config.
  An operator who needs to start one specific VM uses
  `Start-VmIfStopped` directly. A future `-VmName` filter could be
  added without breaking the no-argument default; v1 deliberately
  ships without it to avoid inventing a parameter surface before a
  real demand materialises.
- **Parallel start-up.** VMs are started sequentially. `Start-VM`
  returns once Hyper-V has accepted the command (not once the guest
  is booted), so the wall-clock cost of sequential starts is small
  and the log output stays readable. Parallelism would need a
  thread-safe summary aggregator for a benefit that does not justify
  the complexity at the current VM counts.
- **Mid-run state changes.** If the operator (or another tool) starts
  a VM during the run, this script's `Get-VM` inside
  `Start-VmIfStopped` may see the post-change state and report
  `AlreadyRunning` rather than `Started`. That is the correct outcome
  (the goal is "VM is running", not "this script started it") and is
  pinned by the upstream contract.
- **Migrating the bootstrap to `Get-InfrastructureSecret`.**
  `Infrastructure.Secrets` already ships
  [Get-InfrastructureSecret](../../../../../Infrastructure-Secrets/Infrastructure.Secrets/Public/Get-InfrastructureSecret.ps1)
  + `Use-MicrosoftPowerShellSecretStoreProvider`, which would let
  `Read-VmProvisionerConfig` delete its direct `Get-SecretVault` /
  `Get-Secret` calls in favour of one provider registration + one
  read. Worth doing as a follow-up that touches the helper in one
  place (now that all three callers go through it); not bundled into
  this feature because the migration also has to revisit the
  "actionable error message when the vault is missing" contract that
  the existing wording established, and conflating the two diffs
  would obscure the intent of each.

---

## Acceptance Criteria

- Running `start-vms.ps1` against a valid `VmProvisionerConfig`
  starts every `Off` VM, resumes every `Saved` VM, no-ops on every
  `Running` VM, and prints one summary line per VM identifying which
  bucket it fell into.
- A config with an unknown VM (no Hyper-V VM matches `vmName`) does
  **not** abort the run. The script records the failure, continues
  to the next VM, and exits 1 after the loop with the failed VM's
  name + reason in the output.
- A VM in `Paused` / `Stopping` / `Starting` / `Saving` is reported
  as a failure (same propagation as the upstream contract), is not
  passed to `Start-VM`, and does not abort the rest of the run.
- An empty `Failed` bucket exits 0; a non-empty `Failed` bucket
  exits 1. The exit code is the only programmatic signal callers
  rely on - the script does not throw past the loop.
- Re-running `start-vms.ps1` with the same config and no external
  state change is a true no-op: every VM reports `AlreadyRunning`,
  exit code 0, no Hyper-V state change. Same idempotency model the
  rest of the repo provides.
- A config containing no VM definitions is treated as a configuration
  error (`ConvertFrom-VmConfigJson` already throws on an empty
  array - the script reuses that signal, does not re-implement it).
- The script does not open an SSH session, does not start the host
  file server, and does not import `Posh-SSH`'s SSH cmdlets. Power-on
  is the only side effect.
- A missing or empty SecretStore vault yields the same actionable
  message `provision.ps1` produces today ("Run setup-secrets.ps1
  first") - the script does not invent new wording. The wording is
  guaranteed identical by both scripts now going through
  `Read-VmProvisionerConfig`.
- After the retrofit, `provision.ps1` and `deprovision.ps1` produce
  byte-for-byte the same console output and error wording they do
  today on the bootstrap path. Their existing test suites pass
  unchanged (any test that spied on the inline `Get-SecretVault` /
  `Get-Secret` calls is moved to the new helper's suite, not
  reworked).
- README's lifecycle order is preserved: `provision` -> `start-vms`
  -> `deprovision`. The new section sits between the first two so
  the doc reads in the order an operator hits the scripts.
