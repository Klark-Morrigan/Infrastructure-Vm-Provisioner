<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1 after Common.PowerShell is loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-BaseImagePatch
#   Applies two first-boot fixes inside a base VHDX so the same patch pass
#   covers both. Both writes happen on the same mounted root partition.
#
#   Patch 1: cloud-init NoCloud datasource
#     The Ubuntu Azure cloud image ships with a datasource restriction:
#       datasource_list: [ Azure ]
#     On a local Hyper-V host, cloud-init cannot reach the Azure IMDS,
#     falls back to 'None', and never reads the seed ISO. This function
#     writes a higher-priority override file (99-nocloud.cfg) into
#     /etc/cloud/cloud.cfg.d/ inside the VHDX to add NoCloud.
#
#   Patch 2: order sshd after cloud-config.service
#     Ubuntu cloud images ship with openssh-server already installed and
#     enabled, so ssh.service binds port 22 at boot - BEFORE cloud-init's
#     'users' and 'set_passwords' modules have provisioned the OS user.
#     The host's TCP-port probe then returns "SSH reachable" while
#     password auth still fails with "Permission denied (password)".
#
#     This patch writes a single drop-in under
#     /etc/systemd/system/ssh.service.d/10-wait-cloud-config.conf
#     adding After=cloud-config.service + Wants=cloud-config.service.
#     ssh.service then waits for cc_users_groups + cc_set_passwords
#     to finish before sshd starts. cloud-config.service was chosen
#     over the broader cloud-init.target because (a) it is a strictly
#     narrower wait - only 'config' stage modules have to finish,
#     not also 'final' stage which runs runcmd and could hang on
#     user content; (b) ordering against cloud-init.target risks an
#     activation deadlock because both ssh.service and
#     cloud-init.target are WantedBy=multi-user.target.
#     cloud-config.service is a single oneshot unit with bounded
#     runtime.
#
#     Why ssh.socket is left untouched:
#       Prior revisions tried two more aggressive shapes and broke
#       the boot:
#         v2 - drop-in on BOTH ssh.service.d/ and ssh.socket.d/.
#              Adding After=cloud-config.service to ssh.socket
#              created an ordering cycle:
#                ssh.socket -> cloud-config.service -> basic.target
#                -> sockets.target -> ssh.socket
#              systemd resolves cycles non-deterministically by
#              deleting one start job; in ~50% of boots it deleted
#              cloud-config.service, so the OS user was never created
#              and SSH password auth failed after 30s.
#         v3 - drop-in on ssh.service.d/, ssh.socket masked to
#              /dev/null. Modern Ubuntu's ssh.service has a hard
#              dependency on ssh.socket (Also=/Requires=/socket
#              activation - exact mechanism varies by release).
#              Masking the socket prevented ssh.service from ever
#              starting; boots reached cloud-init.target but never
#              multi-user.target, ssh never came up.
#     v4 (current) keeps it minimal: only ssh.service gets the
#     drop-in. ssh.socket is untouched so it can still socket-
#     activate ssh.service on the first TCP connect, which then
#     blocks on the After= dependency until cloud-config is done.
#     The orchestrator's TCP probe may briefly see port 22 open
#     before the SSH handshake completes, but the handshake itself
#     blocks until the user exists - which is the property we
#     actually needed.
#
#   Patch 3: neutralise the Azure hotplug netplan for early static IP
#     The Ubuntu Azure cloud image ships /etc/netplan/90-hotplug-azure.yaml
#     with an 'ephemeral' entry that forces dhcp4 on every hv_netvsc NIC
#     NOT named eth0. A router VM's seed renames its two NICs to ext0 /
#     priv0 via netplan set-name, so both match that pattern; the hotplug
#     file's higher priority (90 > the seed's init-local 50-cloud-init.yaml)
#     then shadows the static config at cloud-init's init-local stage. The
#     router seed does overwrite the file, but only in a config-stage
#     write_files entry whose re-apply is deferred to a runcmd
#     `netplan apply` (cloud-final). So ext0 sits on a wrong / absent
#     address from init-local through cloud-config, and because sshd is
#     ordered After=cloud-config.service (Patch 2), the host's DIRECT SSH
#     probe of the router's static IP cannot connect until cloud-final -
#     the bulk of the router's ~250s wait-for-SSH versus ~40s for a
#     single-NIC workload (whose eth0 the hotplug entry never matches).
#     Writing the empty-but-valid override into the BASE IMAGE makes the
#     seed's static network-config the only effective netplan from
#     init-local onward, so ext0 holds its static IP before cloud-config
#     and the probe connects right after it, like the workload. The
#     content is generic (no per-VM data), so the base image is the right
#     layer; the seed's own write_files copy stays as an idempotent
#     safety net for any image not re-patched.
#
#   Patch 4: bake the `acl` package into the base image
#     Ansible's unprivileged become-user handoff grants the target user
#     access to its temp files via setfacl, which ships in the `acl`
#     package that a minimal Ubuntu cloud image omits. The runner register
#     play (Infrastructure-GitHubRunners) installs it as a pre_task, but on
#     a fresh VM that apt task pays a ~61s archive metadata refresh - the
#     single biggest task in that play - dominated by `apt-get update` over
#     the VM's NAT path, not the tiny package. Installing acl once here, in
#     the same VHDX patch pass, amortises that cost into the base image; the
#     play then detects acl present and skips its apt path entirely (it
#     keeps the apt fallback for any host not built from this base image).
#     apt runs inside a chroot of the mounted root so it resolves against
#     the image's own sources.list / dpkg db (version-correct), with
#     /dev, /proc and /sys bind-mounted and a temporary resolv.conf that is
#     restored afterwards so the booted VM is unchanged apart from acl.
#
#   Implementation:
#     1. Skip immediately if the sentinel file is present (already patched).
#     2. Delegate WSL2 readiness to Assert-Wsl2Ready (Common.PowerShell). It
#        runs wsl --install and throws a Wsl2NotReady error if not ready;
#        provision.ps1 catches that specific error and exits with code 0
#        after printing the reboot prompt.
#     3. Mount the VHDX via Mount-VHD (no drive letter).
#     4. Attach the raw disk to the WSL2 kernel with wsl --mount --bare.
#     5. Identify the new block device by diffing lsblk before and after.
#     6. Run a base64-encoded shell script that mounts each partition as ext4,
#        finds the root by checking /etc/os-release, writes 99-nocloud.cfg,
#        and syncs to flush kernel write buffers before detach.
#     7. Unmount and dismount in a finally block (always runs).
#     8. Create the sentinel file so subsequent runs skip steps 2-7.
#
#   Parameters:
#     BaseImagePath  - absolute path to the base .vhdx to patch.
#     SentinelPath   - absolute path to the sentinel file that marks the
#                      patch as done (conventionally
#                      <base>.image-patched-v6). The version suffix is
#                      bumped on every substantive change so existing
#                      cached images get re-patched and pick up the fix:
#                        v1: After=cloud-init.target (sshd never started)
#                        v2: drop-in on ssh.service AND ssh.socket
#                            (ordering cycle, cloud-config skipped ~50%
#                            of boots, SSH password auth then failed)
#                        v3: drop-in on ssh.service, ssh.socket masked
#                            (multi-user.target never reached because
#                            masking ssh.socket broke ssh.service)
#                        v4: drop-in on ssh.service only, ssh.socket
#                            untouched
#                        v5: + Patch 3, empty 90-hotplug-azure.yaml so
#                            the router's static netplan wins at
#                            init-local (early static IP for the SSH probe)
#                        v6: + Patch 4, `acl` baked into the base image so
#                            the runner register play's ~61s apt install
#                            no-ops
#                      The re-patch run also removes obsolete drop-in
#                      files left behind by prior revs.
# ---------------------------------------------------------------------------

function Invoke-BaseImagePatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $BaseImagePath,

        [Parameter(Mandatory)]
        [string] $SentinelPath
    )

    if (Test-Path $SentinelPath) {
        return    # already patched on a previous run - nothing to do
    }

    Write-Host "  Patching datasource config in base image ..."

    # WSL2 is required for wsl --mount (kernel) and wsl -u root (distro).
    # Assert-Wsl2Ready (Common.PowerShell) installs WSL2 if missing and
    # throws Wsl2NotReady so provision.ps1 can prompt for reboot and exit 0.
    Assert-Wsl2Ready

    # Attach the base VHDX as a raw disk (no drive letter - Windows
    # cannot read the ext4 partition, so assigning one would only
    # cause a 'Format disk?' prompt).
    $patchVhd    = Mount-VHD -Path $BaseImagePath -NoDriveLetter -PassThru
    $patchDiskNr = $patchVhd.DiskNumber
    $physDrive   = "\\.\PhysicalDrive$patchDiskNr"

    try {
        # Approach: wsl --mount --bare attaches the raw disk to the WSL2
        # kernel without mounting any partitions. The kernel then exposes
        # all partitions as /dev/sdXN block devices inside WSL, which we
        # can mount and inspect from a shell script. This avoids the
        # unreliable wsl --mount --partition N + --name path, where N's
        # meaning varies across WSL builds and --name may not create the
        # mount at the expected path.

        # Snapshot the current block devices so we can identify the new
        # one after --bare attachment.
        $devsBefore = @(
            wsl -u root -e sh -c "lsblk -d -o NAME --noheadings 2>/dev/null" 2>&1 |
            Where-Object { $_ -match '^\S+$' }
        )

        wsl --unmount $physDrive 2>&1 | Out-Null
        $bareOut = wsl --mount $physDrive --bare 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw (
                "wsl --mount --bare failed (exit $LASTEXITCODE): $bareOut. " +
                "Ensure WSL2 (not WSL1) is installed and this script is " +
                "running as Administrator."
            )
        }

        # Identify the newly attached disk.
        $devsAfter = @(
            wsl -u root -e sh -c "lsblk -d -o NAME --noheadings 2>/dev/null" 2>&1 |
            Where-Object { $_ -match '^\S+$' }
        )
        $newDevs = @($devsAfter | Where-Object { $devsBefore -notcontains $_ })
        if ($newDevs.Count -ne 1) {
            # 0-new with `before` containing several sdX is the usual
            # symptom of stale --mount state from a prior interrupted
            # patch (WSL silently no-ops the new mount). Hint at the
            # canonical fix so the operator does not have to dig.
            $hint = if ($newDevs.Count -eq 0 -and $devsBefore.Count -gt 1) {
                ' Likely stale wsl --mount state from a prior interrupted ' +
                'run; run `wsl --shutdown` from an elevated host shell and ' +
                're-run the provisioner.'
            } else { '' }
            throw (
                "Expected exactly 1 new block device after --bare mount, " +
                "found $($newDevs.Count): $($newDevs -join ', '). " +
                "lsblk before: $($devsBefore -join ',')  " +
                "lsblk after:  $($devsAfter  -join ',')." + $hint
            )
        }
        $diskDev = "/dev/$($newDevs[0].Trim())"
        Write-Host "  Attached as WSL block device: $diskDev"

        # Shell script: iterate partition devices (sdX1, sdX2, ...), try
        # mounting each as ext4, confirm root by checking /etc/os-release,
        # then write both patches (cloud-init NoCloud datasource + sshd
        # ordering drop-in) and sync before unmounting. sync ensures
        # kernel buffers are flushed to the backing VHDX before we detach,
        # which prevents a silent data-loss scenario where the writes
        # succeed in kernel memory but never reach disk.
        #
        # Patch 2 writes the same drop-in into both ssh.service.d/ and
        # ssh.socket.d/. ssh.socket may not exist on every image (Ubuntu
        # Server defaults to ssh.service); an orphan drop-in directory is
        # harmless to systemd, so writing both unconditionally is simpler
        # than introspecting which unit is active.
        #
        # The script is encoded as base64 so it can be passed to WSL as a
        # single argument to 'echo', avoiding:
        #   - temp file path issues (spaces, /mnt/c/ permission gaps)
        #   - wsl.exe argument-splitting on multi-word -c strings
        # Base64 is [A-Za-z0-9+/=] only - safe as an unquoted sh arg.
        $patchScriptLines = @(
            "M=/tmp/vmpatch"
            'mkdir -p "$M"'
            "for P in ${diskDev}[0-9]*; do"
            '  [ -b "$P" ] || continue'
            '  if mount -t ext4 "$P" "$M" 2>/dev/null; then'
            '    if [ -f "$M/etc/os-release" ]; then'
            '      CFG="$M/etc/cloud/cloud.cfg.d"'
            '      mkdir -p "$CFG"'
            '      printf "datasource_list: [ NoCloud, None ]\n" > "$CFG/99-nocloud.cfg"'
            # Drop-in lands on ssh.service ONLY. Prior revisions tried
            # two other shapes and broke the boot:
            #   v2: drop-in on ssh.service AND ssh.socket. Adding
            #       After=cloud-config.service to ssh.socket creates
            #       a cycle (ssh.socket -> cloud-config.service ->
            #       basic.target -> sockets.target -> ssh.socket).
            #       systemd resolves cycles non-deterministically by
            #       deleting one start job; in ~50% of boots it
            #       deleted cloud-config.service, so cc_users_groups
            #       never ran and SSH auth failed.
            #   v3: drop-in on ssh.service, ssh.socket masked
            #       (/dev/null symlink). Modern Ubuntu's ssh.service
            #       depends on ssh.socket (Also= / Requires= /
            #       implicit socket activation - exact mechanism
            #       varies by release). Masking the socket prevents
            #       ssh.service from EVER starting; the boot stalls
            #       after cloud-init.target reaches and never gets
            #       to multi-user.target.
            # v4 keeps it minimal: only ssh.service has the
            # After/Wants. ssh.socket is left alone. ssh.service can
            # still start via its own [Install] section, and any
            # socket activation triggered by an early TCP connect
            # blocks until cloud-config finishes because of the
            # After= dependency on the activated ssh.service.
            '      DROP="$M/etc/systemd/system/ssh.service.d"'
            '      mkdir -p "$DROP"'
            '      printf "[Unit]\nAfter=cloud-config.service\nWants=cloud-config.service\n" > "$DROP/10-wait-cloud-config.conf"'
            '      rm -f "$DROP/10-wait-cloud-init.conf"'
            # Clean up artefacts from v2 (drop-in on ssh.socket.d/)
            # and v3 (ssh.socket masked via /dev/null symlink) so a
            # base image patched by an older provisioner version is
            # left in a known-clean state by the re-patch.
            '      rm -rf "$M/etc/systemd/system/ssh.socket.d"'
            # One-line guarded delete: only remove ssh.socket from
            # /etc/systemd/system/ if it is the v3 /dev/null symlink.
            # Real ssh.socket lives in /lib/systemd/system/ on Ubuntu
            # cloud images, so any /etc/systemd/system/ssh.socket file
            # is either the v3 mask symlink or operator override.
            '      if [ -L "$M/etc/systemd/system/ssh.socket" ] && [ "$(readlink "$M/etc/systemd/system/ssh.socket")" = "/dev/null" ]; then rm -f "$M/etc/systemd/system/ssh.socket"; fi'
            # Patch 3: overwrite the Azure hotplug netplan with an empty
            # (but valid) document so it stops shadowing the seed's static
            # network-config at init-local. See the header for why the
            # router's set-name-renamed NICs are shadowed and a workload's
            # eth0 is not. mkdir -p guards the (normally present) dir; 0600
            # matches the seed's write_files permissions for the same path.
            '      mkdir -p "$M/etc/netplan"'
            '      printf "network:\n  version: 2\n" > "$M/etc/netplan/90-hotplug-azure.yaml"'
            '      chmod 0600 "$M/etc/netplan/90-hotplug-azure.yaml"'
            # Patch 4: bake the `acl` package into the base image. Ansible's
            # unprivileged become-user handoff shells out to setfacl (shipped
            # in the acl package, which minimal Ubuntu omits); on a fresh VM
            # the runner register play otherwise pays a ~61s archive metadata
            # refresh to apt-install it. Baking it once amortises that into
            # this one-time base-image patch, after which the play's apt task
            # detects it present and skips its whole refresh+install path.
            # apt runs inside a chroot so it resolves against the IMAGE's own
            # sources.list and dpkg db (version-correct), with /dev, /proc and
            # /sys bind-mounted from the WSL host and a temporary resolv.conf
            # for DNS. The image's original resolv.conf (a systemd-resolved
            # symlink) is captured and restored so the VM boots unchanged.
            '      mount --bind /dev  "$M/dev"'
            '      mount --bind /proc "$M/proc"'
            '      mount --bind /sys  "$M/sys"'
            '      RESTORE_MODE=none'
            '      if [ -L "$M/etc/resolv.conf" ]; then RLINK=$(readlink "$M/etc/resolv.conf"); rm -f "$M/etc/resolv.conf"; RESTORE_MODE=link;'
            '      elif [ -e "$M/etc/resolv.conf" ]; then mv "$M/etc/resolv.conf" "$M/etc/resolv.conf.vmpatchbak"; RESTORE_MODE=file; fi'
            '      printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > "$M/etc/resolv.conf"'
            '      ACL_RC=0'
            '      chroot "$M" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get update || ACL_RC=1'
            # apt stdout (dozens of Get:/progress lines) is dropped so the
            # only thing this script writes to stdout stays the OK:/FAIL:
            # sentinel the PS layer parses; stderr is kept so a real apt
            # error still surfaces in the captured output on failure.
            # Acquire::Languages=none skips the Translation-* indexes (a large
            # share of the metadata) - we only need Packages to resolve acl,
            # and this is a throwaway cache (lists are removed below anyway).
            '      if [ "$ACL_RC" = 0 ]; then chroot "$M" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends acl >/dev/null || ACL_RC=1; fi'
            '      chroot "$M" apt-get clean 2>/dev/null'
            '      rm -rf "$M/var/lib/apt/lists/"* 2>/dev/null'
            '      rm -f "$M/etc/resolv.conf"'
            '      if [ "$RESTORE_MODE" = link ]; then ln -s "$RLINK" "$M/etc/resolv.conf";'
            '      elif [ "$RESTORE_MODE" = file ]; then mv "$M/etc/resolv.conf.vmpatchbak" "$M/etc/resolv.conf"; fi'
            '      umount "$M/sys" 2>/dev/null; umount "$M/proc" 2>/dev/null; umount "$M/dev/pts" 2>/dev/null; umount "$M/dev" 2>/dev/null'
            # Patch 4 is best-effort: if the apt bake failed (e.g. transient
            # WSL network), the boot-critical Patches 1-3 are already written,
            # so we still succeed and let the register play's fallback install
            # acl at runtime. ACL_RC is carried out in the OK line so the PS
            # layer can warn without failing the provision.
            '      echo "OK:$P:acl=$ACL_RC:$(ls $CFG)"'
            '      sync'
            '      umount "$M"'
            '      rmdir "$M"'
            '      exit 0'
            '    fi'
            '    umount "$M" 2>/dev/null'
            '  fi'
            'done'
            "echo FAIL:no_root_on_${diskDev}"
            "lsblk ${diskDev} 2>&1"
            'rmdir "$M" 2>/dev/null'
            'exit 1'
        )
        $scriptUtf8 = [System.Text.Encoding]::UTF8.GetBytes(
            $patchScriptLines -join "`n"
        )
        $scriptB64  = [Convert]::ToBase64String($scriptUtf8)

        $patchOut = wsl -u root -e sh -c "echo $scriptB64 | base64 -d | sh" 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Root ext4 patch failed (exit $LASTEXITCODE): $patchOut"
        }

        # patchOut is "OK:<device>:acl=<rc>:<cfg dir listing>"
        # The listing must include 99-nocloud.cfg (our file), confirming we
        # wrote to the correct partition. acl=<rc> reports Patch 4's exit
        # code: 0 = acl baked in, non-zero = bake skipped (best-effort; the
        # register play installs it at runtime instead).
        if ("$patchOut" -notmatch '^OK:') {
            throw "Unexpected patch output (expected OK:...): $patchOut"
        }
        $aclRc = if ("$patchOut" -match ':acl=([^:]+):') { $Matches[1] } else { '?' }
        Write-Host "  cloud.cfg.d: $($patchOut -replace '^OK:[^:]+:acl=[^:]+:','')"
        Write-Host "  [OK] NoCloud datasource enabled in base image." `
            -ForegroundColor Green
        if ($aclRc -eq '0') {
            Write-Host "  [OK] acl package baked into base image." `
                -ForegroundColor Green
        } else {
            # Non-fatal: boot-critical patches already applied. The runner
            # register play's acl pre_task installs it at runtime instead.
            Write-Warning (
                "acl bake into base image failed (rc=$aclRc; likely WSL " +
                "network). The register play will apt-install acl at runtime."
            )
        }
    }
    finally {
        wsl --unmount $physDrive 2>&1 | Out-Null
        Dismount-VHD -Path $BaseImagePath
    }

    # Create the sentinel so subsequent runs skip the patch.
    New-Item -ItemType File -Path $SentinelPath -Force | Out-Null
}
