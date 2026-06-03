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
#                      <base>.image-patched-v4). The version suffix is
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
