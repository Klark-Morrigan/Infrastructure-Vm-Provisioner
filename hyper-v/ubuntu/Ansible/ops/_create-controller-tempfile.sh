#!/usr/bin/env bash
# Creates a temp file BOTH the launching shell and the WSL Ansible controller
# can open, and spells its path for the far side.
#
# Why this is not just `mktemp`: an ops/ wrapper composes its --extra-vars
# document (and the timing rows file) BEFORE the Common-Ansible bridge is
# reached, and the bridge re-execs itself into WSL when it was launched from
# Git Bash (_run-playbook.sh's uname switch). Forwarded args cross that
# boundary VERBATIM - MSYS2_ARG_CONV_EXCL is set precisely so they are not
# rewritten - so a path minted on the near side has to still name the same
# bytes on the far side.
#
# The bytes are in fact already shared: Git Bash's /tmp IS the Windows temp
# directory. Only the spelling differs - /tmp/x there, /mnt/c/Users/.../x
# under WSL - so nothing needs relocating, just translating. Skipping that
# translation is what made ansible-playbook fail with "Could not find or
# access ... on the Ansible Controller".
#
# The shell test duplicates the bridge's uname switch deliberately: a consumer
# has to classify its own shell BEFORE it can call the bridge, so it cannot
# ask the bridge which side it is on. TEMP is NOT the signal - MSYS rewrites
# it to /tmp on entry, so it reads as POSIX even under Git Bash.
#
# Sourced, not executed - callers want the functions in their own shell.

# shellcheck source=hyper-v/ubuntu/Ansible/ops/_to-wsl-path.sh
source "${BASH_SOURCE[0]%/*}/_to-wsl-path.sh"

# create_controller_tempfile <name-prefix>
#
# Prints the created file's path in the CALLER's dialect, so the caller can
# write to it and remove it. Pass it through resolve_controller_path before
# handing it to ansible-playbook.
# Confidentiality comes from where the file lands, not from a mode bit. On the
# controller mktemp creates 0600 regardless of umask. Under MSYS the same call
# yields 0644 and a chmod does NOT change it - MSYS maps no POSIX mode onto
# NTFS by default - but the file sits in the per-user Windows temp directory,
# which is already ACL'd to that user. So there is deliberately no chmod here:
# it would be a no-op on the side that appears to need it, and misleading
# reassurance on the side that does not. The documents carry config-derived
# paths rather than credentials in any case.
create_controller_tempfile() {
    local prefix="$1"
    local path
    path="$(mktemp -t "${prefix}.XXXXXX")" || return 1
    printf '%s' "${path}"
}

# resolve_controller_path <path>
#
# Prints the path the WSL controller must use to open <path>. A controller-side
# caller gets its input back untouched. Returns non-zero with a message on
# stderr when the path cannot be expressed for the controller.
resolve_controller_path() {
    local path="$1"
    local kernel
    local win

    # Assigned separately so the command substitution's exit status is not
    # masked by `case` (shellcheck SC2312).
    kernel="$(uname -s)"

    case "${kernel}" in
        MINGW* | MSYS* | CYGWIN*)
            if ! command -v cygpath >/dev/null 2>&1; then
                printf 'cygpath is required to translate %s for the WSL controller\n' "${path}" >&2
                return 1
            fi
            # cygpath consults the MSYS mount table, so this holds even where
            # /tmp is mapped somewhere other than the default Windows temp.
            win="$(cygpath -w "${path}")" || return 1
            _to_wsl_path "${win}"
            ;;
        *)
            printf '%s' "${path}"
            ;;
    esac
}
