#!/usr/bin/env bash
# Acquires, verifies, and stages the toolchain artifacts on the Windows host,
# then reports what the bridge and the roles need. This is the consumer-domain
# half of the host-file-server flow: deciding WHICH artifacts (and pinning
# them). The substrate file server
# (Common-Ansible ops/virtual-machines/_stage-host-fileserver.sh) only SERVES a
# directory - it knows nothing of toolchains - so this repo, which owns the
# estate's egress, resolves + verifies + stages the artifacts and hands the
# bridge the staged directory and its version through the CA_HOST_FILE_SERVER_*
# contract (see provision-toolchains.sh).
#
# One pwsh.exe round-trip into Stage-ToolchainArtifacts.ps1, which reads the
# Toolchains desired-state, resolves each loose pin to a concrete build,
# downloads + checksum-verifies each artifact, stages it under the exact
# archive name the role pulls by, and writes a resolved-config document of the
# concrete pins.
#
# Output contract (stdout, in the order emitted):
#
#   STAGING_DIR=<windows-form directory the file server serves>
#   STAGING_VERSION=<digest of the staged set; the file server's version tag>
#   RESOLVED_CONFIG_WSL=</mnt-form path to the concrete pinned-versions JSON>
#
# All three are consumed by provision-toolchains.sh: the first two become
# CA_HOST_FILE_SERVER_DIR / CA_HOST_FILE_SERVER_VERSION, and the third is
# forwarded to ansible-playbook as an --extra-vars override so the roles
# install exactly the pinned builds staging verified. Progress narration goes
# to stderr so it never corrupts the KEY=value contract on stdout.

set -euo pipefail

# shellcheck source=hyper-v/ubuntu/Ansible/ops/imports/_log.sh
source "${BASH_SOURCE[0]%/*}/imports/_log.sh"
# _to_windows_path (shared from Common-Automation) turns the sibling .ps1 path
# into the Windows form pwsh.exe needs.
# shellcheck source=hyper-v/ubuntu/Ansible/ops/imports/_to-windows-path.sh
source "${BASH_SOURCE[0]%/*}/imports/_to-windows-path.sh"
# Generic unknown-flag handler lives in the substrate; reach it through the
# 3.1 sibling-checkout resolver rather than duplicating it here.
# shellcheck source=hyper-v/ubuntu/Ansible/ops/imports/_common-ansible-root.sh
source "${BASH_SOURCE[0]%/*}/imports/_common-ansible-root.sh"
# shellcheck source=/dev/null
source "${common_ansible_root}/ops/_die-on-unknown-flag.sh"

suffix=""
suffix_set=0

usage() {
    echo "usage: _stage-toolchain-artifacts.sh --suffix <secret-suffix>" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --suffix)
            suffix="${2-}"
            suffix_set=1
            shift 2 || true
            ;;
        *)
            _die_on_unknown_flag "$1"
            ;;
    esac
done

if [[ "${suffix_set}" -ne 1 || -z "${suffix}" ]]; then
    usage
    exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stage_ps1="$(_to_windows_path "${script_dir}/Stage-ToolchainArtifacts.ps1")"

log_info "Acquiring + verifying + staging toolchain artifacts (downloads on a cache miss) ..."
# Capture stdout (the KEY=value contract); the PowerShell progress + any error
# ride stderr straight to the terminal, so a failure surfaces its cause.
if ! stage_out="$(pwsh.exe -NoProfile -NoLogo \
        -File "${stage_ps1}" \
        -SecretSuffix "${suffix}")"; then
    log_err "toolchain acquisition/staging failed (PowerShell error above)"
    exit 1
fi
stage_out="${stage_out//$'\r'/}"

staging_dir="$(grep     '^STAGING_DIR='     <<<"${stage_out}" | head -n1 | cut -d= -f2-)"
staging_version="$(grep '^STAGING_VERSION=' <<<"${stage_out}" | head -n1 | cut -d= -f2-)"
resolved_win="$(grep    '^RESOLVED_CONFIG='  <<<"${stage_out}" | head -n1 | cut -d= -f2-)"
if [[ -z "${staging_dir}" || -z "${staging_version}" || -z "${resolved_win}" ]]; then
    log_err "staging helper did not return STAGING_DIR/STAGING_VERSION/RESOLVED_CONFIG"
    exit 1
fi

# The resolved-config path comes back Windows-form (Stage-ToolchainArtifacts
# runs under pwsh.exe). ansible-playbook reads it under the WSL controller, so
# translate C:\... -> /mnt/c/... : every backslash to a slash (the [\\] class
# keeps the backslash a plain literal for shellcheck), then the drive letter to
# a lowercased /mnt mount (\L is GNU sed, which Git Bash ships). The staging dir
# stays Windows-form - the listener pwsh.exe wants exactly that.
resolved_wsl="$(printf '%s' "${resolved_win}" \
    | sed -E 's#[\\]#/#g; s#^([A-Za-z]):/#/mnt/\L\1/#')"

log_info "Toolchain artifacts staged: ${staging_dir}"

printf 'STAGING_DIR=%s\n'         "${staging_dir}"
printf 'STAGING_VERSION=%s\n'     "${staging_version}"
printf 'RESOLVED_CONFIG_WSL=%s\n' "${resolved_wsl}"
