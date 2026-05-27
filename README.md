# Infrastructure-VM-Provisioner

> Reusable Windows scripting tooling for automated Hyper-V VM provisioning and removal.

## Index

- [Overview](#overview)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [setup-secrets.ps1](#setup-secretsps1)
  - [Optional: install a JDK](#optional-install-a-jdk)
  - [Removing a JDK](#removing-a-jdk)
  - [JDK list shape (multiple entries)](#jdk-list-shape-multiple-entries)
  - [Optional: install a .NET SDK](#optional-install-a-net-sdk)
  - [Optional: install .NET global tools](#optional-install-net-global-tools)
  - [Optional: copy files to the VM](#optional-copy-files-to-the-vm)
    - [Bulk entries](#bulk-entries)
  - [Optional: set system-wide environment variables](#optional-set-system-wide-environment-variables)
- [provision.ps1](#provisionps1)
- [start-vms.ps1](#start-vmsps1)
- [deprovision.ps1](#deprovisionps1)
- [CI](#ci)
- [Repo structure](#repo-structure)

---

## Overview

General-purpose, reusable Windows scripting tooling for automated Hyper-V VM
provisioning. Not specific to any single project — intended to be consumed by
other projects that need self-hosted infrastructure.

Automates creation and removal of Hyper-V VMs on Windows 11, with Ubuntu
installed and a default user configured via cloud-init. All parameters are
stored in an AES-256 encrypted local vault scoped to the Windows user account
— nothing sensitive is committed to the repo.

---

## Requirements

PowerShell 7+ (`pwsh`). Windows PowerShell 5.1 is not supported.

---

## Quick start

**Prerequisites:** Windows 11 with Hyper-V enabled, PowerShell 7+, and
Administrator privileges. WSL2 is installed automatically by `provision.ps1`
on first run if not already present (a reboot may be required).
`Infrastructure.Common` and `Infrastructure.Secrets` are installed from
PSGallery automatically on first run.

```powershell
# 1. Store config in the local vault (once per machine)
.\hyper-v\ubuntu\setup-secrets.ps1 -ConfigFile C:\private\vm-config.json

# 2. Provision VMs (run as Administrator)
.\hyper-v\ubuntu\provision.ps1

# 3. Bring VMs back up after a reboot (run as Administrator)
.\hyper-v\ubuntu\start-vms.ps1

# 4. Remove VMs when no longer needed (run as Administrator)
.\hyper-v\ubuntu\deprovision.ps1
```

---

## setup-secrets.ps1

Run once per machine before `provision.ps1`.

```powershell
# Recommended: read config from a file outside the repo
.\setup-secrets.ps1 -ConfigFile C:\private\vm-config.json

# Optional: require a vault-level password on top of Windows user scope
.\setup-secrets.ps1 -ConfigFile C:\private\vm-config.json -RequireVaultPassword
```

Installs `Microsoft.PowerShell.SecretManagement` and
`Microsoft.PowerShell.SecretStore` if missing, registers the `VmProvisioner`
vault, validates the JSON, and stores it as the `VmProvisionerConfig` secret.
Re-running safely updates the stored config.

**Config file format** — a JSON array, one object per VM:

```jsonc
[
  {
    "vmName":        "ubuntu-01-ci",
    "cpuCount":      2,
    "ramGB":         4,
    "diskGB":        40,
    "ubuntuVersion": "24.04",
    "username":      "u-01-admin",
    "password":      "...",
    "ipAddress":     "192.168.1.101",
    "subnetMask":    "24",
    "gateway":       "192.168.1.1",
    "dns":           "8.8.8.8",
    "vmConfigPath":  "E:\\a_VMs\\Hyper-V\\Config",
    "vhdPath":       "E:\\a_VMs\\Hyper-V\\Disks"
  }
]
```

All fields are required. After first boot, connect via `ssh username@ipAddress`.

| Field           | Type   | Description                                        |
|-----------------|--------|----------------------------------------------------|
| `vmName`        | string | Name in Hyper-V and as the VM's hostname           |
| `cpuCount`      | int    | Number of virtual processors                       |
| `ramGB`         | int    | RAM in GB (static allocation)                      |
| `diskGB`        | int    | OS disk size in GB                                 |
| `ubuntuVersion` | string | Ubuntu release, e.g. `"24.04"`                     |
| `username`      | string | OS user created by cloud-init on first boot        |
| `password`      | string | Password for that user (plain text in vault only)  |
| `ipAddress`     | string | Static IPv4 address assigned inside the VM         |
| `subnetMask`    | string | CIDR prefix length, e.g. `"24"`                    |
| `gateway`       | string | Default gateway — also assigned to the host vNIC   |
| `dns`           | string | DNS server IP                                      |
| `vmConfigPath`  | string | Windows path where seed ISO is written             |
| `vhdPath`       | string | Windows path where VHDX files are stored           |
| `switchName`    | string | Hyper-V Internal switch name. Default: `VmLAN`     |
| `natName`       | string | Windows NAT rule name. Default: `VmLAN-NAT`        |
| `javaDevKit`    | object? | Optional. Installs a JDK system-wide on first boot. See [Optional: install a JDK](#optional-install-a-jdk). |
| `dotnetSdk`     | object? | Optional. Installs a .NET SDK system-wide on first boot. See [Optional: install a .NET SDK](#optional-install-a-net-sdk). |
| `dotnetTools`   | array?  | Optional. Installs .NET global tools system-wide on first boot. Requires `dotnetSdk` on the same VM. See [Optional: install .NET global tools](#optional-install-net-global-tools). |
| `files`         | array?  | Optional. Copies arbitrary host files onto the VM. See [Optional: copy files to the VM](#optional-copy-files-to-the-vm). |
| `envVars`       | object? | Optional. Writes a managed block of system-wide environment variables into `/etc/environment`. See [Optional: set system-wide environment variables](#optional-set-system-wide-environment-variables). |

### Optional: install a JDK

Add a `javaDevKit` object to any VM entry to install a JDK system-wide on
first boot. When absent, no JDK is installed and the rest of provisioning is
unaffected.

```jsonc
{
  "vmName": "dev-01",
  "...":    "...",
  "javaDevKit": {
    "vendor":  "temurin",
    "version": "21"
  }
}
```

| Sub-field   | Type      | Required | Default | Allowed values                                                |
|-------------|-----------|----------|---------|---------------------------------------------------------------|
| `vendor`    | string    | yes      | —       | `temurin` (Adoptium Temurin — currently the only supported vendor). |
| `version`   | string    | yes      | —       | A **string** in one of four granularities (see below).         |

`javaDevKit` is also accepted as `null` or `[]` to **uninstall** any JDK
the reconciler previously installed — see [Removing a JDK](#removing-a-jdk) —
and as a single-element list `[{ vendor, version }]` for forward
compatibility with the multi-version shape; see
[JDK list shape](#jdk-list-shape-multiple-entries).

Version-string granularities — pick the level of pinning that suits you:

| Example         | Meaning                                          |
|-----------------|--------------------------------------------------|
| `"21"`          | Latest GA of feature release 21                  |
| `"21.0"`        | Latest GA on the 21.0 line                       |
| `"21.0.5"`      | Latest build of 21.0.5                           |
| `"21.0.5+11"`   | Exact build, no resolution                       |

`version` must be a JSON string. Numeric values like `21` are rejected so that
`"21.0"` cannot silently degrade to `21` through trailing-zero loss, and so
that `"21.0.5+11"` (not a valid JSON number) follows the same rule as the
other granularities.

At provision time the requested granularity is resolved against the
[Adoptium v3 API](https://api.adoptium.net/q/swagger-ui/) to a concrete build
(for example `"21"` -> `21.0.6+7`) along with its SHA-256 and download URL.
The resolved build is then pinned in a host-side lockfile next to the cached
tarball so subsequent provisioning runs reuse the exact same bytes — no
silent upgrades between runs.

**Cache artifacts** — written into `vhdPath` (same directory as the cached
Ubuntu VHDX):

| File                                                | Purpose                                                                 |
|-----------------------------------------------------|-------------------------------------------------------------------------|
| `jdk-{vendor}-{requestedVersion}-linux-x64.tar.gz`  | The Temurin tarball, keyed by the requested (not resolved) version.     |
| `jdk-{vendor}-{requestedVersion}-linux-x64.lock.json` | Sidecar pin recording `resolvedVersion`, `sha256`, `sourceUrl`, and download timestamp. |
| `dotnet-tool-{id}-{version}.nupkg`                  | A .NET global tool's NuGet package, prefetched once on the host so VMs never contact `nuget.org` directly. Verified against the registration-leaf SHA-512 and the nuget.org repo countersignature before being committed to the cache. |
| `dotnet-tool-{id}-{version}.lock.json`              | Sidecar pin recording `sha512`, `source` URL, and acquisition timestamp. A re-run with a matching SHA short-circuits to a cache hit without re-fetching or re-verifying. |

The cache key uses the **requested** version, so two VMs that both ask for
`"21"` share one cache slot. The lockfile is authoritative on subsequent
runs — the resolver is not re-invoked — so a `"21"` request cannot silently
upgrade to a newer build between provisionings.

To invalidate the pin:

- **Delete the lockfile** to force re-resolution against the live Adoptium
  API on the next run (use this to pull in a newer build for a coarse
  request like `"21"`).
- **Delete only the tarball** to trigger a self-heal redownload of the
  exact build the lockfile pinned to (useful when the cached file is
  corrupt but the pin is still wanted).

Neither file is committed — the cache lives entirely on the host, same
trust model as the cached Ubuntu VHDX.

**On the VM** — after the VM is up and cloud-init has finished, the
post-provisioning orchestrator pushes the cached tarball over its
already-open SSH session via the host file server (the same mechanism
`Infrastructure-GitHubRunners` uses to ship the actions-runner binary).
The reconciler's JDK provider then extracts the tarball into the
install directory via `Infrastructure.HyperV`'s `Expand-VmTarball`
primitive (atomic dir-swap, no intermediate file on the VM disk),
wires up `/usr/local/bin` symlinks for every JDK binary, and writes a
system-wide environment script:

| Location                              | Purpose                                                                          |
|---------------------------------------|----------------------------------------------------------------------------------|
| `/opt/jdk-{vendor}-{resolvedVersion}/` | Install root. Path embeds the *resolved* build so coexisting installs do not collide if the requested version is later bumped. |
| `/etc/profile.d/jdk.sh`               | Exports `JAVA_HOME` and prepends `$JAVA_HOME/bin` to `PATH`. Sourced by every login shell automatically. |

The install runs **out-of-band**, not via cloud-init `runcmd`. cloud-init's
job is to bootstrap the OS; the provisioner installs optional software.
Same pattern as the runner install in Infrastructure-GitHubRunners. This
keeps the seed ISO's lifecycle short (it carries the plaintext admin
password and is detached as soon as SSH is reachable) and avoids putting
cloud-init stage knowledge into the host provisioner.

Because the export script lives under `/etc/profile.d/`, any user account
later created on the VM — including those provisioned by
[Infrastructure-Vm-Users](https://github.com/VitaliiAndreev/Infrastructure-Vm-Users) —
sees `JAVA_HOME` and `java` on `PATH` without any additional configuration
in that repo. This is the deliberate split of responsibilities: the
provisioner owns "software the box needs"; Vm-Users owns identities.

Re-runs are idempotent through the reconciler's manifest-driven diff:
if the on-VM `javaDevKit-<resolvedVersion>.json` manifest already
records the desired version, the reconciler reports it as a no-op and
nothing on the VM is touched.

### Removing a JDK

To remove a previously installed JDK from a long-lived VM without
rebuilding it, set `javaDevKit` to `null` (or an empty array `[]`) on
the same VM entry and re-run `provision.ps1`:

```jsonc
{
  "vmName": "dev-01",
  "...":    "...",
  "javaDevKit": null
}
```

The reconciler treats absence of the field as "this VM has no opinion
about JDKs" (skip) and explicit `null` / `[]` as "ensure none
installed". On the VM, the manifest written at install time
(`/var/lib/infra-provisioner/manifests/javaDevKit-*.json`) drives the
teardown: every install dir, `/usr/local/bin` symlink, and
`/etc/profile.d/jdk.sh` recorded there is removed, then the manifest
itself last so a crash mid-uninstall leaves a recovery anchor for the
next run to replay against.

Once the JDK is gone, the cleanest follow-up is to **delete the field
entirely**. The reconciler then sees nothing to do for `javaDevKit` and
stays a clean no-op.

The host-side tarball cache under `vhdPath` is **not** touched — it is
keyed by `{vendor, requestedVersion}` and may be shared with other VMs
that still want the install.

### JDK list shape (multiple entries)

For forward compatibility with the multi-version contract the reconciler
plans to support, `javaDevKit` also accepts a list:

```jsonc
{
  "javaDevKit": [
    { "vendor": "temurin", "version": "21" }
  ]
}
```

v1 supports one JDK per VM, so the list is capped at one entry. A
longer list fails schema with the observed count. Use the list shape
only when the multi-version surface lands; the scalar form remains the
recommended way to declare a single JDK.

### Optional: install a .NET SDK

Add a `dotnetSdk` object to any VM entry to install a .NET SDK system-wide
on first boot. When absent, no .NET SDK is installed and the rest of
provisioning is unaffected. The provider is registered alongside
`javaDevKit` and shares the same reconciler lifecycle (install on first
provision, no-op on re-runs, removal via `null` / `[]`).

```jsonc
{
  "vmName": "dev-01",
  "...":    "...",
  "dotnetSdk": {
    "channel": "10.0",
    "version": "10.0.100"
  }
}
```

| Sub-field   | Type   | Required | Default | Allowed values                                          |
|-------------|--------|----------|---------|---------------------------------------------------------|
| `channel`   | string | yes      | —       | `<major>.<minor>` (e.g. `"10.0"`). Selects the release-metadata channel. |
| `version`   | string | yes      | —       | A **string** in one of three granularities (see below). |

`dotnetSdk` is also accepted as `null` or `[]` to **uninstall** any .NET
SDK the reconciler previously installed (same `null` / `[]` semantics as
`javaDevKit`) and as a single-element list `[{ channel, version }]` for
forward compatibility with the multi-version shape. v1 supports one
SDK per VM, so a longer list fails schema with the observed count.

The install extracts the tarball into `/opt/dotnet-{resolvedVersion}/`,
writes `/etc/profile.d/dotnet.sh` exporting `DOTNET_ROOT`, `PATH`, and
`DOTNET_CLI_TELEMETRY_OPTOUT=1`, and creates `/usr/local/bin/dotnet` as a
symlink to the driver so non-login shells (cron, systemd, `ssh user@host
cmd`) also resolve `dotnet`. Telemetry is opted out by default — these
VMs are unattended CI runners with no operator to consent.

Version-string granularities — pick the level of pinning that suits you:

| Example       | Meaning                                                    |
|---------------|------------------------------------------------------------|
| `"10"`        | Latest SDK on the channel (major-only)                     |
| `"10.0"`      | Latest SDK on the channel (major.minor)                    |
| `"10.0.100"`  | Exact SDK feature-band build                               |

Both `channel` and `version` must be JSON strings. Numeric values like
`10.0` are rejected so `"10.0"` cannot silently degrade to `10` through
trailing-zero loss — the same rule the `javaDevKit.version` field
enforces.

### Optional: install .NET global tools

Add a `dotnetTools` array to any VM entry to install one or more
[.NET global tools](https://learn.microsoft.com/dotnet/core/tools/global-tools)
system-wide on first boot. The field is opt-in — absent or empty arrays
leave the VM untouched — and **requires `dotnetSdk` on the same VM** (the
SDK is needed to run `dotnet tool install`). Entries install in array
order; a failure on any entry fails the provisioning, same posture as
the JDK and SDK installs.

```jsonc
{
  "vmName": "ci-runner-01",
  "...":    "...",
  "dotnetSdk":   { "channel": "10.0", "version": "10.0.100" },
  "dotnetTools": [
    { "id": "dotnet-reportgenerator-globaltool", "version": "5.4.4" }
  ]
}
```

| Sub-field | Type   | Required | Allowed values                                                                 |
|-----------|--------|----------|--------------------------------------------------------------------------------|
| `id`      | string | yes      | A NuGet package id matching `^[A-Za-z0-9._-]+$`.                               |
| `version` | string | yes      | An **exact NuGet version pin**. No `"latest"`, no floating ranges (`[1.0,2.0)`), no whitespace. Reproducibility takes priority; if a version needs to move, edit the JSON. |

Unknown sub-fields are rejected at schema time to catch silent typos
(`versoin` vs `version`), the same strict-by-design posture
`dotnetSdk` and `javaDevKit` take.

`dotnetTools` is also accepted as `null` or `[]` to **uninstall** any
.NET global tools the reconciler previously installed. `dotnetTools: []`
is allowed regardless of whether `dotnetSdk` is set — "no tools" is a
coherent state on any VM, SDK or not.

### Optional: copy files to the VM

Add a `files` array to any VM entry to copy arbitrary host files onto the
VM after cloud-init finishes. Each entry is a `{ source, target }` pair —
local Windows path on the host, absolute Linux path on the VM.

```jsonc
{
  "vmName": "dev-01",
  "...":    "...",
  "files": [
    { "source": "C:\\jars\\mylib-1.0.jar", "target": "/opt/lib/mylib-1.0.jar" },
    { "source": "C:\\fixtures\\seed.json", "target": "/var/data/seed.json" }
  ]
}
```

| Sub-field | Required | Notes                                                                  |
|-----------|----------|------------------------------------------------------------------------|
| `source`  | yes      | Windows path. **Must exist at validation time** — typos fail before any VM work begins. |
| `target`  | yes      | Absolute Linux path on the VM (must start with `/`). Parent directory is created if absent. |

The copy is performed over the same SSH session and host file server used
by other post-provisioning steps (see [provision.ps1](#provisionps1) step
10). The actual file transfer is delegated to
`Infrastructure.HyperV`'s `Copy-VmFiles` cmdlet — the validator that
backs the schema (`Assert-VmFilesField`) also lives there. Both are
reused by `Infrastructure-Vm-Users` for its own (user-owned) file copies.
Re-runs overwrite the target file with the current host source —
the user's intent is "this file should look like this".

**Ownership model in the provisioner**: every file copied by this step
lands `root:root, 0644`. The provisioner runs *before* user creation, so
no app users exist yet to chown to. Files needing a per-user owner belong
in `Infrastructure-Vm-Users`'s `files` array, which runs after that step
creates the users.

`files` is **purely user data** — no install step (JDK, future Maven, …)
reads from these paths. Each install is self-contained. This keeps the
contract simple: the user owns the target paths and what lives there.

#### Bulk entries

For a directory of related files (a JAR classpath, a fixtures tree, ...),
a bulk entry copies every match of a host wildcard under one VM target
directory without enumerating each file in the config. Single and bulk
entries can be mixed freely in the same `files` array.

```jsonc
{
  "vmName": "ci-01",
  "...":    "...",
  "files": [
    { "pattern": "C:\\jars\\*.jar", "targetDir": "/opt/ci-jars" }
  ]
}
```

| Sub-field              | Required | Default | Notes                                                                                                  |
|------------------------|----------|---------|--------------------------------------------------------------------------------------------------------|
| `pattern`              | yes      | —       | Host-side wildcard accepted by `Get-ChildItem -Path`. Must match at least one file when the transport runs. |
| `targetDir`            | yes      | —       | Absolute Linux directory on the VM (must start with `/`). Created if absent.                            |
| `recurse`              | no       | `false` | Descend into subdirectories of `pattern`'s root.                                                        |
| `preserveRelativePath` | no       | `false` | Mirror the host subtree under `targetDir` instead of flattening every match to its basename. Useful for a Maven-style tree. |

`source` and `pattern` are mutually exclusive on a single entry — mixing
them is a validation error so the intent stays unambiguous. Bulk entries
land `root:root, 0644`, same as single entries, with the same ownership
rationale described above.

Each bulk entry runs as its own `Copy-VmFilesByPattern` call, dispatched
in JSON order alongside any single entries in the same array. Errors
(zero matches, target-path collisions) are reported per entry, before
any SSH I/O happens for that entry — so a misspelled pattern names
itself in the failure instead of being lost in a batched run.

The transport is delegated to `Infrastructure.HyperV`'s
[`Copy-VmFilesByPattern`](https://github.com/VitaliiAndreev/Infrastructure-HyperV/blob/master/Infrastructure.HyperV/Public/FileTransfer/Copy-VmFilesByPattern.ps1) —
see its notes for the exact wildcard semantics (including the zero-match
and target-collision pre-flight errors raised before any SSH I/O).

### Optional: set system-wide environment variables

Add an `envVars` object to any VM entry to write a sentinel-delimited
managed block of `NAME="VALUE"` lines into `/etc/environment`. Unlike
`/etc/profile.d/*.sh` snippets (sourced only by login shells), this file
is read by `pam_env` for every login — including the non-login shells
spawned by systemd-managed services.

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

| Sub-field           | Required | Notes                                                                                                                                                              |
|---------------------|----------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `blockName`         | yes      | Sentinel name for the managed block (`# BEGIN <blockName>` / `# END <blockName>`). Operator-chosen so multiple consumers (this provisioner, Vm-Users, ...) can coexist. Validated against `^[A-Za-z0-9._ -]+$`, 1-128 chars, no leading / trailing whitespace. |
| `entries`           | yes      | Array of `{ name, value }` pairs. May be empty — see the removal note below.                                                                                       |
| `entries[].name`    | yes      | POSIX identifier (`^[A-Za-z_][A-Za-z0-9_]*$`). Unique across entries.                                                                                              |
| `entries[].value`   | yes      | Non-empty, no `\n` / `\r` / `\0`. Written as `NAME="VALUE"` with `"` and `\` escaped.                                                                              |

Lines outside the managed block — Ubuntu's default `PATH=...`, any
operator additions, other consumers' blocks — are preserved
byte-for-byte across re-runs. The file's ownership and mode stay
`root:root, 0644`, the only mode `pam_env` reliably reads.

Omitting `envVars` on a subsequent run is a **no-op** — the previously
written block stays put. To remove the block explicitly, set
`entries: []` on the same VM entry and re-run `provision.ps1`; the
transport treats an empty array as "remove this managed block". Same
explicit-removal model as the JDK `uninstall` flag.

The transport is delegated to `Infrastructure.HyperV`'s
[`Set-VmEnvironmentVariables`](https://github.com/VitaliiAndreev/Infrastructure-HyperV/blob/master/Infrastructure.HyperV/Public/EnvVars/Set-VmEnvironmentVariables.ps1) —
see its notes for the exact managed-block, atomic-write, and
skip-unchanged semantics.

---

## provision.ps1

Run as Administrator after `setup-secrets.ps1` has stored the config.

```powershell
.\provision.ps1
```

Reads `VmProvisionerConfig` from the vault and for each VM definition:

1. Validates all required fields.
2. Classifies each entry as **new** (no Hyper-V VM with this `vmName`
   exists AND the `ipAddress` is silent), **existing** (Hyper-V VM
   exists AND the `ipAddress` responds — the VM is up), or **skipped**
   (any other combination). New VMs get the full destructive pipeline;
   existing VMs are *reconciled* — only the idempotent additive steps
   (host-side acquisitions and post-provisioning) run, so adding
   `javaDevKit` / `files` / etc. to a VM definition and re-running
   `provision.ps1` pushes the change without re-creating the VM. The
   two skipped cases get a warning explaining why:
   - VM is absent but the IP responds → static-IP conflict with an
     unknown machine.
   - VM exists but the IP does not respond → VM is offline; start it
     and re-run.

   The steps below note which classifications they apply to.
3. **(new VMs only)** Downloads the Ubuntu cloud image (`.vhd.tar.gz`)
   from the Ubuntu CDN into `vhdPath` once per `ubuntuVersion`, converts
   it to `.vhdx`, and caches it. On first download it also patches the
   base image via WSL2 to enable the NoCloud cloud-init datasource
   (required for Hyper-V — the Azure image ships with Azure-only
   datasource config). Subsequent runs reuse the cached, patched base
   image — no re-download or re-patch.
4. **(new VMs only)** Copies the base image to a per-VM disk
   (`{vmName}.vhdx`) and resizes it to `diskGB`.
5. **(new AND existing VMs)** Runs host-side acquisitions for each VM
   via a small per-VM orchestrator (`Invoke-VmAcquisitions`). It
   dispatches one acquirer per opt-in field:
   - **`javaDevKit`** acquires the requested Temurin tarball into
     `vhdPath` (see [Optional: install a JDK](#optional-install-a-jdk)).
     Skipped when `javaDevKit` is `null` or `[]` — the reconciler's
     "ensure none installed" signal needs no tarball.
   - **`dotnetSdk`** acquires the requested .NET SDK tarball into the
     same `vhdPath` cache as JDK tarballs, using the same
     `{software}-{requestedVersion}-linux-x64.tar.gz` + sidecar
     `.lock.json` naming convention (see
     [Optional: install a .NET SDK](#optional-install-a-net-sdk)).
     Skipped when `dotnetSdk` is `null` or `[]` for the same reason.
   - **`dotnetTools`** acquires each requested .NET global tool's
     `.nupkg` from `nuget.org` into the same `vhdPath` cache
     (filenames `dotnet-tool-{id}-{version}.nupkg` and matching
     `.lock.json`). The host verifies SHA-512 and the nuget.org repo
     countersignature before committing bytes to the cache, so VMs
     never contact `nuget.org` directly. Skipped when `dotnetTools`
     is absent, `null`, or `[]`.

   Skipped silently for VMs that have no opt-in fields. Each acquirer is
   idempotent via its on-host lockfile, so a re-run against an already-
   cached artefact is cheap. New acquirers plug in as one dispatch line
   in the orchestrator, not a new step here.
6. **(new VMs only)** Generates a cloud-init seed ISO
   (`{vmName}-seed.iso`) in `vmConfigPath` containing `meta-data` and
   `user-data`. On first boot cloud-init reads the
   ISO to create the OS user, enable SSH, and apply the static IP - no
   interactive installer needed. The static IP is installed via
   `user-data` `write_files`: cloud-init drops the netplan document at
   `/etc/netplan/99-static.yaml` (mode `0600`) and a sibling
   `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg` containing
   `network: {config: disabled}` so cloud-init's network module never
   rewrites `/etc/netplan/*.yaml` again. A `runcmd: netplan apply`
   activates the config during first boot. Netplan - not cloud-init -
   owns the on-disk file for the life of the VM, so reboots and
   cloud-init re-evaluations cannot revert the static config to DHCP.
7. **(always)** Creates a Hyper-V Internal switch named `VmLAN` (if
   absent), assigns the `gateway` IP to the host-side virtual NIC, and
   adds a `New-NetNat` rule for the subnet so VMs can reach the internet
   through the host. Idempotent; runs even when only existing VMs are
   being reconciled so a rebuilt host gets the network re-applied.
8. **(new VMs only)** Creates each VM (Gen 2, static RAM, VHDX from
   step 4), sets Secure Boot to `MicrosoftUEFICertificateAuthority`
   (required for Ubuntu), attaches the seed ISO, connects to `VmLAN`,
   and starts the VM. Polls port 22 until cloud-init finishes, then
   detaches and deletes the seed ISO.
9. **(new AND existing VMs)** Runs post-provisioning. Opens one host file server and
    one SSH session per VM, waits once for cloud-init to finish, then
    dispatches each enabled step:
    - **`files`** copies host files to declared VM paths (each entry is
      dispatched in JSON order: single entries via `Copy-VmFiles`, bulk
      entries via `Copy-VmFilesByPattern`; see
      [Optional: copy files to the VM](#optional-copy-files-to-the-vm)).
    - **`javaDevKit`** is now reconciler-owned (see the Reconciler
      subsection below) — the JDK provider extracts the prefetched
      Temurin tarball into `/opt/jdk-{vendor}-{resolvedVersion}/`,
      writes `/etc/profile.d/jdk.sh`, wires `/usr/local/bin` symlinks
      for every JDK binary, and records all owned paths in a sidecar
      manifest (see [Optional: install a JDK](#optional-install-a-jdk)).
      Setting the field to `null` or `[]` drives the manifest-based
      removal — see [Removing a JDK](#removing-a-jdk).
    - **`envVars`** writes a sentinel-delimited managed block of
      `NAME="VALUE"` lines into `/etc/environment` via
      `Set-VmEnvironmentVariables` (see
      [Optional: set system-wide environment variables](#optional-set-system-wide-environment-variables)).
      Dispatched after `files` and `javaDevKit` so a value pointing at
      content one of the earlier steps placed is referencing something
      that already exists when the file is rewritten.

    Each step is self-contained — no step consumes files left by another
    step. Adding a new step (e.g. Maven) is a one-function addition with
    one dispatch line in `Invoke-VmPostProvisioning`. Skipped silently
    for VMs that have no opt-in fields. Idempotent on the VM side: the
    JDK install no-ops when its `release` file is already present, file
    copies overwrite with the current host source bytes, and the
    env-vars step skips the SSH write when the desired block already
    matches what is on disk.

    ### Reconciler

    Post-provisioning also runs a toolchain **reconciler** in parallel
    with the legacy `files` / `javaDevKit` / `envVars` branches. For each
    VM the orchestrator:

    1. Calls `Initialize-VmManifestStore` once, creating
       `/var/lib/infra-provisioner/manifests/` (root:root, 0755) — the
       single source of truth for "what is installed by the reconciler
       on this VM".
    2. Calls `Invoke-ToolchainReconciliation` with the array returned by
       `Get-Providers`. Each provider declares the JSON sub-field it
       owns (e.g. `javaDevKit`, `dotnetSdk`) and the four operations
       — `Get-DesiredVersions`, `Get-InstalledVersions`,
       `Install-Version`, `Uninstall-Version` — the orchestrator
       dispatches in JSON-declaration order.

    Registered providers (in dispatch order):

    | Provider              | JSON field    | Notes                                                                                                                                                                                                                                       |
    |-----------------------|---------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
    | `JdkProvider`         | `javaDevKit`  | Manifest-driven install/uninstall of one Temurin JDK per VM.                                                                                                                                                                                |
    | `DotnetSdkProvider`   | `dotnetSdk`   | Manifest-driven install/uninstall of one .NET SDK per VM. Exports `DOTNET_ROOT`, `DOTNET_TOOLS_ROOT`, and sets `DOTNET_CLI_TELEMETRY_OPTOUT=1` via `/etc/profile.d/dotnet.sh`. `PATH` prepends both the SDK install dir and the tools dir.   |
    | `DotnetToolsProvider` | `dotnetTools` | Nested under `DotnetSdkProvider`. Manifest-driven install/uninstall of one or more .NET global tools system-wide under `/usr/local/share/dotnet/tools/`, with per-command symlinks under `/usr/local/bin/`. One manifest per `(id, version)`. |

    See
    [docs/dev/implementation/42 - dotnet sdk/](docs/dev/implementation/42%20-%20dotnet%20sdk/)
    for the full provider contract.

    **Nested providers (hybrid dispatch).** A provider may declare
    a `ParentProvider` field naming another provider's `Name`.
    Nested providers run in the orchestrator's main loop just like
    top-level providers, in `Get-Providers` array order (convention:
    a parent appears before its children). The `ParentProvider`
    field is pure metadata used by the children walker built into
    `Invoke-ToolchainReconciliation`: before a parent provider's
    `Uninstall-Version` runs, the walker reads the parent manifest's
    `children` array (each entry is `{ provider, manifestPath }`)
    and dispatches the matching nested provider's `Uninstall-Version`
    first, so a child install that lives under the parent's install
    dir is torn down before its host directory disappears. Every
    other operation (install, standalone uninstall, diff/NoOp) goes
    through the main loop, including for nested providers — so a
    child install fires even when the parent's diff is a NoOp. A
    child entry that names an unregistered provider produces a
    warning and leaves the child in place rather than blocking the
    parent's removal forever. The first real consumer of this
    contract is `DotnetToolsProvider` (global `dotnet` nuget tools
    nested under `DotnetSdkProvider`) — see
    [feature 43](docs/dev/implementation/43%20-%20dotnet%20nuget/).

    **Guest layout for `dotnetTools`.** Tools install system-wide
    under `/usr/local/share/dotnet/tools/` (the `--tool-path` argument
    to `dotnet tool install`). Each installed tool's commands are
    discovered by parsing `dotnet tool list --tool-path …` output and
    surfaced as symlinks under `/usr/local/bin/{cmd}` so non-login
    shells (sshd command exec, systemd units, cron) find them without
    sourcing `/etc/profile.d/`. Login shells pick the same dir up
    automatically because `DotnetSdkProvider`'s `/etc/profile.d/dotnet.sh`
    prepends `DOTNET_TOOLS_ROOT` to `PATH`.

---

## start-vms.ps1

Run as Administrator after VMs have been created by `provision.ps1` to bring
every VM in `VmProvisionerConfig` back to `Running` after a host reboot, a
manual shutdown, or a Hyper-V "Saved" state caused by a host power event.

```powershell
.\start-vms.ps1
```

Reads the same `VmProvisionerConfig` from the vault and for each VM calls
`Start-VmIfStopped` from
[Infrastructure-HyperV](https://github.com/VitaliiAndreev/Infrastructure-HyperV) —
see that repo for the per-VM state-machine contract (`Off` -> Started,
`Saved` -> Resumed, `Running` -> AlreadyRunning, transient states throw).

**Idempotency** — re-running with no external state change is a true no-op:
every VM reports `AlreadyRunning`, exit code 0, no Hyper-V state change.

**Per-VM failure policy** — a single bad VM (unknown to Hyper-V, in a
transient state, etc.) does not strand the rest of the list. Each failure
is recorded and surfaced after the loop with the upstream reason; the
script exits 1 if any failure was recorded and 0 otherwise. Exit code is
the only programmatic signal — the script does not throw past the loop.

The script does **not** open an SSH session, start the host file server,
or run any post-provisioning step. "Power on" is a distinct concern from
"power on + reachable"; callers who need the latter compose `start-vms.ps1`
with their own `Wait-VmSshReady` loop. Hyper-V's native per-VM
`AutomaticStartAction` covers the auto-start-on-boot case and is
deliberately not what this script does.

---

## deprovision.ps1

Run as Administrator to remove VMs that were created by `provision.ps1`.

```powershell
.\deprovision.ps1
```

Reads the same `VmProvisionerConfig` from the vault and for each VM definition:

1. Validates all required fields.
2. Stops the VM if running, then removes it from Hyper-V. If the VM is already
   absent (re-run after a partial failure), the Hyper-V step is skipped and
   only file cleanup is attempted.
3. Deletes the per-VM VHDX (`{vmName}.vhdx`) in `vhdPath`. If Windows VMMS
   still holds a handle after `Remove-VM`, deletion is retried up to 5 times
   with exponential backoff (capped at 30 s) via `Invoke-WithRetry` from
   `Infrastructure.Common` using the file-lock retry strategy. If the file is
   still locked after all retries the script throws with the path identified
   — re-running after a few seconds retries the deletion.
4. Deletes the seed ISO (`{vmName}-seed.iso`) in `vmConfigPath` if present.
   `provision.ps1` removes it after first boot, so absence is not an error.
5. Deletes the VM configuration directory (`{vmConfigPath}/{vmName}/`) if
   present, with the same retry logic as the VHDX.

After all VMs are processed:

6. Removes the `VmLAN-NAT` NAT rule, the gateway IP from the host vNIC, and
   the `VmLAN` Internal switch — but only when no VMs remain connected to the
   switch. If VMs outside the config are still attached (e.g. provisioned
   separately), the network teardown is skipped to preserve their connectivity.

**The base Ubuntu image is not deleted.** It is shared across all VMs of the
same Ubuntu version and is not specific to any single config entry. Delete it
manually from `vhdPath` if it is no longer needed.

---

## CI

CI runs on pull requests targeting `master` via `.github/workflows/ci.yml`,
which delegates to the shared reusable workflow in
[Infrastructure-Common](https://github.com/VitaliiAndreev/Infrastructure-Common):

```
VitaliiAndreev/Infrastructure-Common/.github/workflows/ci-powershell.yml@master
```

The shared workflow runs `Run-Tests.ps1` on PowerShell 7.
No additional CI configuration is needed in this repo.

---

## Repo structure

```
Infrastructure-VM-Provisioner/
|- .github/
|  `- workflows/
|     `- ci.yml              # Delegates to shared ci-powershell.yml in Infrastructure-Common
|- hyper-v/
|  `- ubuntu/
|     |- provision.ps1       # Entry point - orchestrates all provisioning steps
|     |- start-vms.ps1       # Entry point - brings provisioned VMs back to Running
|     |- deprovision.ps1     # Entry point - reverses provision.ps1
|     |- setup-secrets.ps1   # One-time vault setup
|     |- common/
|     |  `- config/
|     |     |- ConvertFrom-VmConfigJson.ps1  # JSON parsing and validation; delegates the optional 'files' array to Infrastructure.HyperV's Assert-VmFilesField
|     |     |- Assert-JavaDevKitField.ps1    # Validates optional javaDevKit field
|     |     |- Get-SanitizedVmDisplay.ps1    # Masks password in diagnostic output
|     |     `- Read-VmProvisionerConfig.ps1  # Shared bootstrap helper: vault read + schema validation, reused by provision / start-vms / deprovision
|     |- up/
|     |  |- config/
|     |  |  `- Select-VmsForProvisioning.ps1 # Pre-flight VM-existence and IP-conflict checks
|     |  |- disk/
|     |  |  |- Invoke-DiskImageAcquisition.ps1  # Downloads, converts, caches base VHDX
|     |  |  `- Invoke-BaseImagePatch.ps1        # Patches cloud-init datasource via WSL2
|     |  |- jdk/
|     |  |  |- Resolve-AdoptiumRelease.ps1            # Resolves version granularity via Adoptium v3 API
|     |  |  |- Invoke-JdkAcquisition.ps1              # Downloads + verifies tarball, writes lockfile pin
|     |  |  |- Get-JdkBinariesForSymlinking.ps1       # Enumerates the JDK bin/ dir on the VM for /usr/local/bin symlink wiring
|     |  |  |- JdkProvider.Get-DesiredVersions.ps1    # Reconciler op: parses javaDevKit into typed Spec records
|     |  |  |- JdkProvider.Get-InstalledVersions.ps1  # Reconciler op: reads JDK manifests from the on-VM store
|     |  |  |- JdkProvider.Install-Version.ps1        # Reconciler op: extracts tarball, writes profile.d + symlinks, records manifest
|     |  |  |- JdkProvider.Uninstall-Version.ps1      # Reconciler op: manifest-driven teardown of one JDK install
|     |  |  `- Get-JdkProvider.ps1                    # Composes the four ops into an IToolchainProvider object
|     |  |- dotnet/
|     |  |  |- Resolve-DotnetSdkRelease.ps1             # Resolves version granularity via Microsoft's release-metadata feed
|     |  |  |- Invoke-DotnetSdkAcquisition.ps1          # Host-side .NET SDK tarball prefetch + lockfile pin
|     |  |  |- Invoke-DotnetToolAcquisition.ps1         # Host-side .nupkg prefetch with SHA-512 + nuget.org repo-signature verification
|     |  |  |- nuget-trusted-signers.config             # Pinned nuget.org trusted-signers config used by 'dotnet nuget verify'
|     |  |  |- DotnetSdkProvider.Get-DesiredVersions.ps1   # Reconciler op: parses dotnetSdk into a typed Spec
|     |  |  |- DotnetSdkProvider.Get-InstalledVersions.ps1 # Reconciler op: reads SDK manifests from the on-VM store
|     |  |  |- DotnetSdkProvider.Install-Version.ps1       # Reconciler op: extracts tarball, writes profile.d, symlinks, manifest
|     |  |  |- DotnetSdkProvider.Uninstall-Version.ps1     # Reconciler op: manifest-driven teardown of one SDK install
|     |  |  |- Get-VmDotnetToolChildren.ps1             # Predicts child-manifest entries for the SDK manifest's `children` array
|     |  |  |- Get-DotnetSdkProvider.ps1                # Composes the SDK ops into an IToolchainProvider; closes over the derived child-manifest entries
|     |  |  |- DotnetToolsProvider.Get-DesiredVersions.ps1   # Reconciler op: parses dotnetTools into typed Spec records
|     |  |  |- DotnetToolsProvider.Get-InstalledVersions.ps1 # Reconciler op: reads tool manifests from the on-VM store
|     |  |  |- DotnetToolsProvider.Install-Version.ps1       # Reconciler op: stages .nupkg, dotnet tool install, /usr/local/bin symlinks, manifest
|     |  |  |- DotnetToolsProvider.Uninstall-Version.ps1     # Reconciler op: ownership-bounded teardown of one tool install
|     |  |  `- Get-DotnetToolsProvider.ps1              # Composes the tools ops into an IToolchainProvider; sets ParentProvider = 'dotnetSdk'
|     |  |- acquire/
|     |  |  `- Invoke-VmAcquisitions.ps1        # Per-VM host-side acquisition orchestrator; dispatches each per-software acquirer guarded by its opt-in field
|     |  |- post/
|     |  |  |- Invoke-VmPostProvisioning.ps1    # Per-VM transport orchestrator (file server + SSH + cloud-init wait), dispatches steps; calls Infrastructure.HyperV's Copy-VmFiles for the 'files' step
|     |  |  `- Set-EnvironmentVariables.ps1     # Step: writes a managed block of NAME="VALUE" lines into /etc/environment via Infrastructure.HyperV's Set-VmEnvironmentVariables
|     |  |- network/
|     |  |  `- setup-network.ps1               # Creates VmLAN switch, host IP, NAT rule
|     |  |- seed/
|     |  |  |- generate-seed-iso.ps1           # Builds cloud-init seed ISO
|     |  |  |- New-StaticNetplanYaml.ps1       # Builds netplan v2 YAML for the VM's static NIC (embedded in user-data write_files)
|     |  |  `- iso.ps1                         # IMAPI2 ISO creation helper
|     |  `- vm/
|     |     `- create-vm.ps1                   # Creates, boots, and polls each VM
|     `- down/
|        |- config/
|        |  `- Assert-GatewayConsistency.ps1 # Validates all VMs share one gateway
|        |- network/
|        |  `- teardown-network.ps1         # Removes NAT rule, host IP, and switch
|        `- vm/
|           `- remove-vm.ps1               # Stops, removes VM, deletes VHDX and config dir
|- Tests/
|  |- common/config/         # Unit tests for common/config helpers
|  |- up/
|  |  |- config/             # Unit tests for up/config helpers
|  |  |- disk/               # Unit tests for up/disk
|  |  |- jdk/                # Unit tests for up/jdk
|  |  |- network/            # Unit tests for up/network
|  |  |- seed/               # Unit tests for up/seed
|  |  `- vm/                 # Unit tests for up/vm
|  `- down/
|     |- config/             # Unit tests for down/config helpers
|     |- network/            # Unit tests for down/network
|     `- vm/                 # Unit tests for down/vm
|- Run-Tests.ps1             # Runs Pester tests (called by ci-powershell.yml)
`- README.md
```

Each scenario follows the `hypervisor/guest-os/` convention. Future scenarios
(e.g. `hyper-v/windows-server/`, `vmware/ubuntu/`) extend the tree without
changing the root structure. Each scenario folder is self-contained — its own
scripts, its own secrets setup, its own README if needed.

**Recommended specs for a self-hosted GitHub Actions runner:**

| Resource | Value  | Reasoning                                                                          |
|----------|--------|------------------------------------------------------------------------------------|
| vCPU     | 2      | Realistic minimum with Docker; stack multiple VMs on a well-resourced host         |
| RAM      | 4 GB   | Leaves headroom for 6–7 VMs on a 64 GB host                                       |
| Disk     | 40 GB  | Covers Ubuntu base (~5 GB), runner agent, Docker image cache, and workspace        |
| OS       | 24.04  | Current LTS; matches the `ubuntu-24.04` GitHub-hosted runner label for parity     |
