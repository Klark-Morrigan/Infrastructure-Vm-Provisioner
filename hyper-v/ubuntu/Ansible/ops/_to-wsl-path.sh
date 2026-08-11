#!/usr/bin/env bash
# Converts a Windows path (C:\dir\file) to the WSL mount form the Ansible
# controller reads (/mnt/c/dir/file). The inverse of Common-Automation's
# _to_windows_path, which this repo already imports for the pwsh.exe direction.
#
# Why this exists at all: the estate's config is authored Windows-side, so
# every controller-side path it carries (a `files` entry's source/pattern, the
# resolved-config document staging writes) arrives drive-lettered. The Ansible
# controller runs under WSL, where that same file is only reachable through the
# /mnt automount. Nothing in the substrate bridge translates config-supplied
# paths - and deliberately so: the reusable roles stay topology-agnostic, which
# means the consumer that KNOWS the estate is Windows-hosted owns the
# conversion. This helper is that knowledge, in one place, so the two ops/
# scripts that need it cannot drift apart.
#
# Sourced, not executed - callers want the function, and a subshell per path
# would be pure cost on a bulk `files` array.
#
# If a second repo ever needs this, promote it to Common-Automation
# (scripts/_to-wsl-path.sh) next to its inverse rather than copying it.

# _to_wsl_path <path>
#
# Prints the translated path on stdout. Returns 1 with a message on stderr for
# any input that has no honest /mnt equivalent, so a bad config path fails the
# run at the wrapper rather than surfacing later as an Ansible "file not found"
# against a path nobody recognises.
#
# Accepted:
#   C:\dir\file  /  c:/dir/file  /  C:/dir\file   -> /mnt/c/dir/file
#   /already/posix                                -> unchanged
#   relative/path                                 -> unchanged
# Rejected:
#   \\server\share\file   (UNC - the automount maps drives, not shares)
#   C:file                (drive-relative - resolves against a per-drive cwd
#                          that does not exist under WSL)
_to_wsl_path() {
    local path="$1"

    # UNC first: it is the only form whose leading characters could otherwise
    # be mistaken for an already-POSIX absolute path.
    if [[ "${path}" =~ ^[/\\][/\\] ]]; then
        printf 'UNC paths have no WSL /mnt equivalent: %s\n' "${path}" >&2
        return 1
    fi

    # No drive letter: already POSIX, or relative to the controller's cwd.
    # Either way it is usable as-is, so pass it through untouched.
    if [[ ! "${path}" =~ ^[A-Za-z]: ]]; then
        printf '%s' "${path}"
        return 0
    fi

    # Drive-qualified but with no separator after the colon (C:file) means
    # "relative to that drive's current directory" - a Windows-only notion with
    # no WSL counterpart, so guessing would be worse than failing.
    if [[ ! "${path}" =~ ^[A-Za-z]:[/\\] ]]; then
        printf 'drive-relative paths are not supported: %s\n' "${path}" >&2
        return 1
    fi

    # The automount is lower-cased regardless of how the drive was written.
    # ${path:2} keeps the leading separator, so it becomes the one between the
    # mount point and the rest of the path.
    local drive="${path:0:1}"
    local remainder="${path:2}"
    printf '/mnt/%s%s' "${drive,,}" "${remainder//\\//}"
}
