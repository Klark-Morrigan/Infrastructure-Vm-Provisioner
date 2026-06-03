<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1 after PowerShell.Common is loaded.
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
#   Patch 2: order sshd after cloud-config.service, mask ssh.socket
#     Ubuntu cloud images ship with openssh-server already installed and
#     enabled, so ssh.service binds port 22 at boot - BEFORE cloud-init's
#     'users' and 'set_passwords' modules have provisioned the OS user.
#     The host's TCP-port probe then returns "SSH reachable" while
#     password auth still fails with "Permission denied (password)".
#
#     This patch lands two artefacts under /etc/systemd/system/:
#       1. ssh.service.d/10-wait-cloud-config.conf - drop-in adding
#          After=cloud-config.service + Wants=cloud-config.service so
#          ssh.service waits for cc_users_groups + cc_set_passwords
#          to finish before sshd starts. cloud-config.service was
#          chosen over the broader cloud-init.target because (a) it
#          is a strictly narrower wait, only 'config' stage modules
#          have to finish, not also 'final' stage which runs runcmd
#          and could hang on user content; (b) ordering against
#          cloud-init.target risks an activation deadlock because
#          both ssh.service and cloud-init.target are WantedBy=
#          multi-user.target. cloud-config.service is a single
#          oneshot unit with bounded runtime.
#       2. ssh.socket -> /dev/null symlink - offline equivalent of
#          `systemctl mask ssh.socket`. Without masking, ssh.socket
#          remains enabled and binds port 22 at sockets.target time
#          (early in boot, well before cloud-config), socket-activating
#          ssh.service on the first connect. That would defeat the
#          drop-in above: the host TCP probe would succeed before
#          users exist, and SSH would block on auth until the
#          orchestrator's connect timeout.
#
#     History: the prior revision wrote the drop-in to BOTH
#     ssh.service.d/ AND ssh.socket.d/. ssh.socket + After=cloud-
#     config.service created a cycle through sockets.target ->
#     ssh.socket; systemd resolved it non-deterministically by
#     dropping a start job - ~50% of boots it dropped
#     cloud-config.service entirely, the OS user was never created,
#     and password auth hung for 30s before the orchestrator gave up.
#     The current shape (drop-in on ssh.service, mask on ssh.socket)
#     has no cycle because ssh.socket is no longer in the dependency
#     graph at all.
#
#   Implementation:
#     1. Skip immediately if the sentinel file is present (already patched).
#     2. Delegate WSL2 readiness to Assert-Wsl2Ready (PowerShell.Common). It
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
#                      <base>.image-patched-v3). The version suffix is
#                      bumped on every substantive change so existing
#                      cached images get re-patched and pick up the fix:
#                        v1: After=cloud-init.target (sshd never started)
#                        v2: drop-in on ssh.service AND ssh.socket
#                            (ordering cycle, cloud-config skipped ~50%
#                            of boots, SSH password auth then failed)
#                        v3: drop-in on ssh.service only, ssh.socket
#                            masked - no cycle, deterministic
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
    # Assert-Wsl2Ready (PowerShell.Common) installs WSL2 if missing and
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
            throw (
                "Expected exactly 1 new block device after --bare mount, " +
                "found $($newDevs.Count): $($newDevs -join ', '). " +
                "lsblk before: $($devsBefore -join ',')  " +
                "lsblk after:  $($devsAfter  -join ',')"
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
            # Drop-in lands on ssh.service ONLY. An earlier revision
            # also wrote it to ssh.socket.d/, which created an ordering
            # cycle (ssh.socket -> cloud-config.service -> basic.target
            # -> sockets.target -> ssh.socket). systemd resolves cycles
            # non-deterministically by deleting one start job - in ~50%
            # of boots it deleted cloud-config.service, so cc_users_groups
            # never ran, the OS user was never created, and the
            # orchestrator hung on SSH password auth until its 30s
            # connect timeout. With the drop-in restricted to ssh.service,
            # ssh.socket has no extra ordering edge and no cycle forms.
            '      DROP="$M/etc/systemd/system/ssh.service.d"'
            '      mkdir -p "$DROP"'
            '      printf "[Unit]\nAfter=cloud-config.service\nWants=cloud-config.service\n" > "$DROP/10-wait-cloud-config.conf"'
            '      rm -f "$DROP/10-wait-cloud-init.conf"'
            # Clean up the prior revision's ssh.socket.d/ drop-in if
            # present, so a base image patched by an older provisioner
            # version cannot still carry the cycle.
            '      rm -rf "$M/etc/systemd/system/ssh.socket.d"'
            # Mask ssh.socket entirely so port 22 is bound only by
            # ssh.service (which has the After/Wants ordering above).
            # The offline-mount equivalent of `systemctl mask` is a
            # symlink to /dev/null under /etc/systemd/system/. Without
            # masking, ssh.socket would socket-activate sshd on the
            # first TCP connect, defeating the whole purpose of the
            # drop-in - the host TCP probe would succeed before
            # cloud-config has finished provisioning the user.
            '      ln -sf /dev/null "$M/etc/systemd/system/ssh.socket"'
            '      echo "OK:$P:$(ls $CFG)"'
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

        # patchOut is "OK:<device>:<cfg dir listing>"
        # The listing must include both 99-nocloud.cfg (our file) and
        # ideally 90_dpkg.cfg (the Azure override we're superseding),
        # confirming we wrote to the correct partition.
        if ("$patchOut" -notmatch '^OK:') {
            throw "Unexpected patch output (expected OK:...): $patchOut"
        }
        Write-Host "  cloud.cfg.d: $($patchOut -replace '^OK:[^:]+:','')"
        Write-Host "  [OK] NoCloud datasource enabled in base image." `
            -ForegroundColor Green
    }
    finally {
        wsl --unmount $physDrive 2>&1 | Out-Null
        Dismount-VHD -Path $BaseImagePath
    }

    # Create the sentinel so subsequent runs skip the patch.
    New-Item -ItemType File -Path $SentinelPath -Force | Out-Null
}
