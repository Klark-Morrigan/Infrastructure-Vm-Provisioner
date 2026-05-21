# Problem: System-Wide Environment Variables on a Provisioned VM

## Index

- [Context](#context)
- [What Is Changing](#what-is-changing)
  - [New `envVars` per-VM field](#new-envvars-per-vm-field)
  - [Validation surface](#validation-surface)
  - [Post-provisioning dispatch](#post-provisioning-dispatch)
- [Why Now](#why-now)
- [Affected Components](#affected-components)
- [Out of Scope](#out-of-scope)
- [Acceptance Criteria](#acceptance-criteria)

---

## Context

`provision.ps1` validates each VM definition in
[ConvertFrom-VmConfigJson.ps1](../../../../hyper-v/ubuntu/common/config/ConvertFrom-VmConfigJson.ps1)
and runs post-provisioning steps via
[Invoke-VmPostProvisioning.ps1](../../../../hyper-v/ubuntu/up/post/Invoke-VmPostProvisioning.ps1).
Today the orchestrator dispatches on two optional fields - `files` (via
`Assert-VmFilesField` + `Copy-VmFiles`) and `javaDevKit` (via
`Install-Jdk` / `Uninstall-Jdk`). Each per-step function runs through
the same already-open SSH session and host file server.

[Install-Jdk](../../../../hyper-v/ubuntu/up/post/Install-Jdk.ps1) writes
`JAVA_HOME` and prepends `$JAVA_HOME/bin` to `PATH` via
`/etc/profile.d/jdk.sh`. That snippet is only sourced by **login**
shells: non-login bash invocations (`bash -c '...'`) and systemd
services do not see it. For the JDK case the `/usr/local/bin/java`
symlink hides the gap, but the trick does not generalise to arbitrary
environment variables a workload needs.

`Infrastructure.HyperV` v0.7 adds the transport this feature consumes:

- [Assert-VmEnvVarsField](../../../../../Infrastructure-HyperV/Infrastructure.HyperV/Public/EnvVars/Assert-VmEnvVarsField.ps1) -
  shared schema validator for an `envVars` object on a VM
  definition. The shape is fixed:
  `{ blockName: string, entries: [{ name, value }] }`. The validator
  is no-op when `envVars` is absent and throws with a descriptive
  message otherwise.
- [Set-VmEnvironmentVariables](../../../../../Infrastructure-HyperV/Infrastructure.HyperV/Public/EnvVars/Set-VmEnvironmentVariables.ps1) -
  per-VM transport that writes a sentinel-delimited managed block
  (`# BEGIN <BlockName>` / `# END <BlockName>`) into
  `/etc/environment` in one SSH round-trip. Lines outside the block,
  and other consumers' blocks, are preserved byte-for-byte.
  Skip-unchanged is on by default and an empty `entries` array
  removes only the named block.

The first concrete consumer is the same CI build farm covered by
[07 - ci jars](../07%20-%20ci%20jars/problem.md): a CI agent running
as a systemd-managed service needs the install root (pointing at the
directory the bulk-files step populated) visible in the non-login
shells the agent spawns - that one path is what the consumer's build
scripts actually read; anything beyond it is operator-supplied.
Project-specific names are an operator concern - the provisioner
treats every entry as an opaque `{ name, value }` pair, same way the
bulk-files step treats paths.

---

## What Is Changing

### New `envVars` per-VM field

Each VM definition grows an optional `envVars` field whose shape
matches the upstream validator's contract one-to-one. The two key
sets are:

```jsonc
{
  "vmName": "ci-01",
  "...":    "...",
  "envVars": {
    "blockName": "ci-01-app",
    "entries": [
      { "name": "FOO_HOME", "value": "/opt/foo" }
    ]
  }
}
```

| Sub-field    | Type     | Required | Notes |
|--------------|----------|----------|-------|
| `blockName`  | string   | yes      | Sentinel name for the managed block in `/etc/environment`. Operator-chosen so multiple consumers (this provisioner, Vm-Users, future tools) can coexist without overwriting each other. Validated against `^[A-Za-z0-9._ -]+$`, 1-128 chars, no leading / trailing whitespace. |
| `entries`    | array    | yes      | Possibly empty. `[]` is a valid intent meaning "remove this managed block on the next run". |
| `entries[].name`  | string | yes | POSIX identifier (`^[A-Za-z_][A-Za-z0-9_]*$`), no `=`. Unique across entries. |
| `entries[].value` | string | yes | Non-empty, no `\n`, `\r`, or `\0`. Written to disk as `NAME="VALUE"` with `"` and `\` escaped. |

Ownership and mode for `/etc/environment` stay `root:root, 0644` -
the only mode `pam_env` reliably reads. The provisioner does not
expose per-entry overrides; per-user scoping belongs to
`Infrastructure-Vm-Users`, which can adopt the same transport later
with its own `blockName`.

### Validation surface

`ConvertFrom-VmConfigJson` adds one new line: a call to
`Assert-VmEnvVarsField` alongside the existing `Assert-JavaDevKitField`
and `Assert-VmFilesField` calls. The validator owns every rule
(blockName format, entry shape, identifier syntax, duplicate detection)
so the provisioner stays a one-call consumer - same shape as the
files validation today. No per-entry post-validator hook is needed
in v1 because the provisioner's policy is "write whatever the
operator wrote, with no per-entry surface of its own".

### Post-provisioning dispatch

[Invoke-VmPostProvisioning.ps1](../../../../hyper-v/ubuntu/up/post/Invoke-VmPostProvisioning.ps1)
gains a third dispatch branch alongside `hasFiles` and `hasJdk`:

- `hasEnvVars`: presence of an `envVars` field on the VM. Dispatches
  to a new self-contained step `Set-EnvironmentVariables` (thin
  per-VM wrapper that pulls `blockName` and `entries` out of the
  VM object and calls `Set-VmEnvironmentVariables`).

The new branch is independent of the others: it shares the SSH
session but not any state. Order between branches stays a stylistic
choice (`files` first, then `javaDevKit`, then `envVars` - cheapest
to reason about because the env-var values may legitimately
reference paths the `files` step placed).

---

## Why Now

- HyperV-03 ships in `Infrastructure.HyperV` v0.7 - the transport
  this feature relies on. Without it the provisioner would either
  reinvent the sentinel / atomic-write logic or drop a profile-only
  snippet via the `files` array, which fails for the CI workload
  that motivates the change.
- The CI build farm scoped by
  [07 - ci jars](../07%20-%20ci%20jars/problem.md) needs the
  install-root path it placed visible to a systemd-managed CI agent.
  The agent spawns non-login shells where `/etc/profile.d/*.sh` is
  not sourced, so the existing JDK trick does not solve the problem.
- Wiring the same shared validator + transport that downstream repos
  will also adopt (Vm-Users, etc.) keeps a single source of truth
  for "what a valid envVars block looks like".

---

## Affected Components

- [hyper-v/ubuntu/common/config/ConvertFrom-VmConfigJson.ps1](../../../../hyper-v/ubuntu/common/config/ConvertFrom-VmConfigJson.ps1) -
  add one `Assert-VmEnvVarsField -Vm $vm` call alongside the
  existing optional-field validators.
- `hyper-v/ubuntu/up/post/Set-EnvironmentVariables.ps1` (new) -
  thin per-VM wrapper around `Set-VmEnvironmentVariables`. Same
  self-contained shape as
  [Install-Jdk.ps1](../../../../hyper-v/ubuntu/up/post/Install-Jdk.ps1)
  (takes `$SshClient` and `$Vm`; throws with `$Vm.vmName` named on
  failure). No `$Server` parameter because env-var writing does
  not stage anything host-side.
- [hyper-v/ubuntu/up/post/Invoke-VmPostProvisioning.ps1](../../../../hyper-v/ubuntu/up/post/Invoke-VmPostProvisioning.ps1) -
  add the `hasEnvVars` predicate, capture
  `$setEnvironmentVariables = ${function:Set-EnvironmentVariables}`
  next to the other captures, and add the dispatch branch.
  The "any opt-in field set" gate becomes
  `($hasFiles -or $hasJdk -or $hasEnvVars)`.
- [hyper-v/ubuntu/provision.ps1](../../../../hyper-v/ubuntu/provision.ps1) -
  dot-source the new `Set-EnvironmentVariables.ps1` next to
  `Install-Jdk.ps1`.
- [hyper-v/ubuntu/Install-ModuleDependencies.ps1](../../../../hyper-v/ubuntu/Install-ModuleDependencies.ps1) -
  bump the `Invoke-ModuleInstall -ModuleName 'Infrastructure.HyperV'`
  `-MinimumVersion` floor to the current HyperV `ModuleVersion` at
  the time this feature is implemented (must be at least the version
  that ships `Assert-VmEnvVarsField` + `Set-VmEnvironmentVariables` -
  `0.7.0`). Same "bump to the latest" rule
  [07 - ci jars Step 1](../07%20-%20ci%20jars/plan.md#step-1---bump-infrastructurehyperv-dependency-to-the-latest)
  uses; if 07 has already landed at a later HyperV version this
  feature's bump may be a no-op.
- [README.md](../../../../README.md) - new "Optional: set system-wide
  environment variables" section with one example, sub-field table,
  and a one-line note that lines outside the block are preserved
  across re-runs. Link to upstream
  `Set-VmEnvironmentVariables` notes for managed-block semantics.
- `Tests/common/config/` and `Tests/up/post/` - extend / add tests
  for the new validator call site and the new dispatch branch.
  Transport behaviour is covered by `Infrastructure-HyperV`'s
  integration suite and is not retested here.

---

## Out of Scope

- **Per-user environment variables.** The provisioner writes the
  `/etc/environment` system-wide file via `pam_env`'s view; per-user
  files (`~/.profile`, `~/.config/environment.d/`) belong to
  `Infrastructure-Vm-Users`, which can adopt the same upstream
  transport with its own `blockName` once user accounts exist.
- **Multiple managed blocks per VM.** The schema allows exactly one
  `envVars` object per VM. If an operator needs more than one block
  on the same VM (e.g. a CI block plus an app block), they call
  `Set-VmEnvironmentVariables` directly from a custom script with
  the second `blockName`; the provisioner does not chain calls. A
  future iteration could promote `envVars` to an array if a real
  demand materialises.
- **Secrets.** Values are written `root:root, 0644` - same as
  today - and end up on disk in plaintext. Secrets belong in
  `Infrastructure-Secrets`; the validator rejects empty values so
  an "I forgot to template the secret" mistake fails loud rather
  than landing an empty key.
- **PATH manipulation as a first-class feature.** Setting
  `PATH=...` works because it is just another key, but
  "prepend / append this directory to the existing PATH" is a
  separate concern (ordering, dedup, conflict with `/etc/profile`).
  Operators who need it set the full PATH explicitly, as today.
- **Removing the `envVars` field across runs.** Omitting `envVars`
  on a subsequent run is a **no-op** - the dispatch branch is gated
  on presence, so the previously-written block stays put. To remove
  the block explicitly, set `entries: []` (which the transport
  treats as "remove this block"). Same model as the JDK uninstall
  flag: removal is an explicit operator action, not an implicit
  side effect of editing the JSON.
- **Combining envVars and JDK lifecycle.** The new branch runs
  regardless of whether the JDK step installs, uninstalls, or is
  absent. Coordinating the two (e.g. "also rewrite JAVA_HOME via
  envVars when installing the JDK") is intentionally not done -
  `Install-Jdk` already owns the JDK's profile snippet, and
  duplicating it via envVars would create two writers for one
  variable.

---

## Acceptance Criteria

- A config containing no `envVars` field behaves bit-for-bit as it
  does today (no regression for current consumers; the new dispatch
  branch is skipped).
- A config with a well-formed `envVars` object parses through
  `ConvertFrom-VmConfigJson` and reaches the post-provisioning step
  with the object preserved.
- Schema validation rejects, before any VM work: an `envVars` that
  is an array or scalar; a missing `blockName` or `entries`;
  unknown sub-fields on either level; a `blockName` that violates
  the format / length rules; an entry with a non-POSIX `name`;
  an entry with an empty / multi-line `value`; duplicate entry
  names.
- A successful first run leaves a sentinel-delimited managed block
  in `/etc/environment` with the operator's entries, ownership
  `root:root`, mode `0644`. Lines outside the block (Ubuntu's
  default `PATH=...`, any operator additions) are preserved.
- Re-running `provision.ps1` with the same config is a no-op for
  externally visible state of the managed block - same idempotence
  the bulk-files step provides.
- A re-run with one key removed from `entries` writes a file in
  which that key's line is gone from the managed block; the rest
  remain.
- A re-run with `entries: []` removes the markers and the block
  entirely; lines outside the block are preserved.
- The dispatch branch is independent of the JDK and files branches:
  a config that sets only `envVars` does not open the file server
  unnecessarily (Vm-side env-var writing does not stage anything
  host-side). When the file server is already open for another
  branch, the env-var step reuses the same SSH session.
- README documents the new field with one example, alongside the
  existing JDK / files examples, and links to the upstream
  `Set-VmEnvironmentVariables` notes for managed-block semantics
  so the schema docs do not duplicate the transport contract.
