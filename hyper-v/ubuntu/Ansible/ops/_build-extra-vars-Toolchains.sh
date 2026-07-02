#!/usr/bin/env bash
# Per-domain extra-vars helper: toolchains. Owned by
# Infrastructure-Vm-Provisioner (the deploying consumer that owns the estate's
# egress) and consumed by the Common-Ansible substrate composer
# (ops/_build-extra-vars.sh). The composer derives this helper by the generic
# _build-extra-vars-<Name>.sh convention from the declared Toolchains vault
# and - because this repo declares CA_CONSUMER_ROOT - resolves it from
# <consumer-root>/ops rather than from the substrate.
#
# Sole job: thread the bridge-resolved host_file_server_base_url to the jdk /
# dotnet_sdk / dotnet_tools roles, which pull their tarballs / packages from
# that URL by archive name. The URL is only known after the bridge starts the
# host file server, so it can reach the roles only through this fragment (the
# composer forwards --host-base-url to every declared vault's helper).
#
# What this fragment deliberately does NOT emit: the toolchain desired-state.
# The Toolchains vault (--config) is the operator's loose desired-state, but
# it is consumed upstream by the acquire/verify/stage step
# (Stage-ToolchainArtifacts.ps1), which resolves it to CONCRETE pins and stages
# the verified artifacts. Those concrete pins reach the roles as an
# --extra-vars override the wrapper forwards, so the target installs exactly
# what staging verified. Re-emitting the loose pins here would let the target
# re-resolve to a newer upstream build than was staged - the drift the pin
# exists to prevent. This fragment still validates --config so a Toolchains
# vault that failed to decrypt fails loud here rather than mid-play.
#
# Output (stdout): {"host_file_server_base_url": "<url>"}

set -euo pipefail

# The shared input gate and the unknown-flag handler are generic substrate
# helpers, not consumer code, so they live in Common-Ansible and are reached
# through the 3.1 sibling-checkout resolver rather than duplicated here.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hyper-v/ubuntu/Ansible/ops/imports/_log.sh
source "${script_dir}/imports/_log.sh"
# shellcheck source=hyper-v/ubuntu/Ansible/ops/imports/_common-ansible-root.sh
source "${script_dir}/imports/_common-ansible-root.sh"
# shellcheck source=/dev/null
source "${common_ansible_root}/ops/_validate-extra-vars-input.sh"
# shellcheck source=/dev/null
source "${common_ansible_root}/ops/_die-on-unknown-flag.sh"

toolchains_path=""
host_base_url=""
host_base_url_set=0

usage() {
    echo "usage: _build-extra-vars-Toolchains.sh --config <path>" \
         "--host-base-url <url> [--runner-version <ver>]" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            toolchains_path="${2:-}"
            shift 2 || true
            ;;
        --host-base-url)
            # ${2-} (no colon) so a literal empty value reaches the non-empty
            # check below rather than being dropped by the default branch.
            host_base_url="${2-}"
            host_base_url_set=1
            shift 2 || true
            ;;
        --runner-version)
            # Forwarded by the composer alongside --host-base-url (the generic
            # file-server pair). The toolchain roles pull by archive name and
            # never read it, so its value is consumed and discarded here rather
            # than rejected as an unknown flag.
            shift 2 || true
            ;;
        *)
            _die_on_unknown_flag "$1"
            ;;
    esac
done

if [[ -z "${toolchains_path}" || "${host_base_url_set}" -ne 1 ]]; then
    usage
    exit 2
fi

if [[ -z "${host_base_url}" ]]; then
    log_err "--host-base-url requires a non-empty value"
    exit 2
fi

# Validate the declared Toolchains vault decrypted to valid JSON, even though
# its content is consumed by the acquire step rather than emitted here: a
# vault that failed to decrypt should fail loud at the substrate boundary.
_validate_extra_vars_input --config "${toolchains_path}"

jq -n --arg u "${host_base_url}" '{host_file_server_base_url: $u}'
