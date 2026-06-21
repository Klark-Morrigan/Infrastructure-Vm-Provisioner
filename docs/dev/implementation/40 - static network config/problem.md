# 40 - Static network config

## Index

- [For laymen](#for-laymen)
- [Symptom](#symptom)
- [How the provisioner does it today](#how-the-provisioner-does-it-today)
- [Why this is brittle](#why-this-is-brittle)
- [What needs to change](#what-needs-to-change)
- [Out of scope](#out-of-scope)

## For laymen

Every VM the provisioner builds is supposed to come up with a fixed IP
address so the host can reach it over SSH. Right
now that IP is set by a one-shot "first boot" mechanism (cloud-init,
fed by a small ISO we attach to the VM). After first boot we delete the
ISO from disk - and from that point on, nothing on the VM is locked
into the static IP. The same software that originally applied it can
later replace it with a "ask the network for an address" (DHCP) config,
which silently breaks because our virtual network has no DHCP server.
A booted VM with no IP cannot be reached.

This is what bit us: an affected VM is running, but has no IPv4
address, so the host cannot SSH in.

## Symptom

Observed on an affected VM (host-side: `Get-VM` shows Running, ping
times out, `arp -a` has no entry; VM-side: `ip -4 addr show` lists only
`lo`):

`/etc/netplan/50-cloud-init.yaml` on the VM contains cloud-init's stock
DHCP fallback, not the static config the provisioner sent:

```yaml
network:
  version: 2
  ethernets:
    eth0:
      match:
        macaddress: "<mac>"
      dhcp4: true
      dhcp6: true
      set-name: "eth0"
```

The NAT segment has no DHCP server, so the NIC ends up with only an
IPv6 link-local address and is unreachable from the host.

## How the provisioner does it today

1. [`generate-seed-iso.ps1`](../../../../hyper-v/ubuntu/up/seed/generate-seed-iso.ps1)
   builds a cloud-init `network-config` (v2 / netplan format) with the
   static IP, gateway and DNS from the per-VM config, matching the NIC
   by `driver: hv_netvsc`.
2. [`iso.ps1`](../../../../hyper-v/ubuntu/up/seed/iso.ps1) packs that
   plus `meta-data` and `user-data` into a NoCloud seed ISO labelled
   `cidata`.
3. [`create-vm.ps1`](../../../../hyper-v/ubuntu/up/vm/create-vm.ps1)
   attaches the ISO as a DVD drive, starts the VM, polls SSH, then
   deletes the ISO file from disk in a `finally` block. The deletion
   is intentional - the ISO contains the plaintext password.
4. Cloud-init's `network` module reads the seed's `network-config`,
   writes `/etc/netplan/50-cloud-init.yaml`, and netplan applies it.

Nothing else on the VM pins the static IP. cloud-init remains in
control of `50-cloud-init.yaml` for the lifetime of the instance.

## Why this is brittle

The current design has at least three failure modes that all produce
the symptom above:

1. **Seed-ISO loss across re-evaluation.** Once the ISO file is
   deleted, the DVD drive points at a missing path. If cloud-init
   re-runs in a state where the cached datasource is unavailable or
   considered stale (manual `cloud-init clean`, image regeneration,
   instance-id mismatch, certain upgrade paths), it cannot re-read
   the seed's `network-config` and falls back to the stock DHCP
   template - which is exactly what we observe.
2. **No `network: {config: disabled}` flag.** Cloud-init's network
   module is enabled by default and is allowed to rewrite
   `50-cloud-init.yaml` on every boot it considers itself
   authoritative. The provisioner installs no
   `/etc/cloud/cloud.cfg.d/*.cfg` to opt out, so any future trigger
   that puts cloud-init back in charge of networking will clobber
   whatever static config was there.
3. **Single source of truth, owned by the wrong layer.** The static
   IP is data the provisioner already has and already applies once.
   Putting cloud-init in the loop adds a regenerator we do not need
   and cannot easily silence after the fact.

A related but distinct concern is the converse case - don't auto-heal
host networking from the provisioner; this problem is entirely VM-side
and is fair game.

## What needs to change

Goal: the static IP, gateway and DNS land in a netplan file that
**netplan owns, not cloud-init**, on first boot, and stay there for
the life of the VM. No SSH-time post-step, no second boot, no
cloud-init re-evaluation can revert it.

Concretely, the provisioner must, as part of the existing seed ISO it
already writes:

- **Disable cloud-init's network management** by writing
  `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg` containing
  `network: {config: disabled}`. After this is in place, cloud-init
  stops touching `/etc/netplan/*.yaml`.
- **Write the static netplan directly** at
  `/etc/netplan/99-static.yaml` with mode `0600`, containing the v2
  config currently in the seed's `network-config` (match by
  `driver: hv_netvsc`, `dhcp4: false`, address/routes/nameservers from
  the per-VM config). `99-` outranks the legacy `50-cloud-init.yaml`
  if one still exists, so behaviour is deterministic during the
  transition.
- **Keep cloud-init for everything else** (user creation,
  `ssh_pwauth`, package install, hostname). Only the network leg
  moves out of cloud-init's control.

These two files are static text we already know how to template; the
cleanest delivery is via the seed `user-data` using cloud-init's
`write_files` module, which runs early enough that the disable flag
is present before cloud-init's network module would otherwise act.

A `netplan apply` (or a one-shot reboot via `runcmd`) on first boot
brings the static config live without needing the host to be able
to SSH in beforehand - which is the chicken-and-egg case that bit us.

## Out of scope

- Migrating *existing* unreachable VMs. The hot-fix for those is to
  apply the same two files at the VM console manually; the broader
  fix here ensures new provisions and reprovisions land correctly.
- Switching off NAT/RRAS/ICS dependencies on the host - the host-side
  networking is healthy in this incident.
- Replacing password-based SSH with key auth. The plaintext-password
  concern that caused the seed ISO to be deleted post-boot is real;
  key-based auth would let us keep the seed around safely, but it is
  a larger change tracked separately.
