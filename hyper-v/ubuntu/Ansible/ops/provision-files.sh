#!/usr/bin/env bash
# Operator wrapper for the Ansible file provisioning flow - the operator-declared
# `files` entries of each VM definition, copied onto the provisioned VMs. The
# flow's heavy lifting (tmpdir, venv activation, vault reads, inventory, router
# resolution, extra-vars, dispatch) lives in the Common-Ansible substrate
# bridge, consumed as a sibling checkout (see README "Consuming Common-Ansible").
# This wrapper owns the one concern the consumer-agnostic bridge intentionally
# does not:
#
# - Controller-side path translation. `files` entries name their sources on the
#   Windows host that authored the config, but ansible-playbook reads them under
#   the WSL controller. _resolve-vm-files-config.sh reshapes the config into the
#   per-host desired-state dict and rewrites every source/pattern to its /mnt
#   form on the way. Doing it here rather than in the role is what keeps the
#   reusable vm_files role free of drive letters and testable in a plain
#   container - only this repo knows the estate is Windows-hosted.
#
# Everything else it declares through the CA_* consumer contract: the
# VmProvisioner inventory vault (which also holds the `files` desired-state, so
# there is no separate vault to declare), and this repo's Ansible-slice root, from
# which the bridge resolves the playbook. The vm_files / files_report roles stay
# substrate, resolved from the sibling checkout.
#
# Notably absent: CA_NEEDS_HOST_FILE_SERVER. The toolchain flow needs a
# Windows-side HttpListener because its roles pull tarballs by URL;
# ansible.builtin.copy pushes bytes through the SSH connection that is already
# open, so this flow needs no listener - and the payloads never leave that
# channel.
#
# Forwarded args follow the playbook path so operators can pass --tags, --limit,
# --check, -v, etc. unchanged.

set -euo pipefail

# SECRET_SUFFIX selects the lifecycle whose secrets this run reads (e.g.
# Production). Required both by the desired-state read below (which vault
# secret) and by the bridge; validate it here so the failure is one clear
# message rather than an opaque empty-suffix error deeper in.
if [[ -z "${SECRET_SUFFIX:-}" ]]; then
    echo "SECRET_SUFFIX must be set (e.g. Production or the caller's lifecycle label)" >&2
    exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This repo's Ansible-slice root (ops/ -> Ansible/): the consumer root the
# bridge resolves the playbook from.
CA_CONSUMER_ROOT="$(cd "${script_dir}/.." && pwd)"

# shellcheck source=hyper-v/ubuntu/Ansible/ops/imports/_log.sh
source "${script_dir}/imports/_log.sh"
# shellcheck source=hyper-v/ubuntu/Ansible/ops/imports/_common-ansible-root.sh
source "${script_dir}/imports/_common-ansible-root.sh"
# shellcheck source=hyper-v/ubuntu/Ansible/ops/imports/_timing.sh
source "${script_dir}/imports/_timing.sh"
# Pulls in _to-wsl-path.sh transitively - this flow only needs the two
# controller-handoff verbs, not the raw translator.
# shellcheck source=hyper-v/ubuntu/Ansible/ops/_create-controller-tempfile.sh
source "${script_dir}/_create-controller-tempfile.sh"
# shellcheck source=hyper-v/ubuntu/Ansible/ops/_dispatch-playbook.sh
source "${script_dir}/_dispatch-playbook.sh"

# Arm the timing emitter (a no-op unless TIMING_TREE_OUTPUT_PATH is set) so the
# E2E orchestrator can graft this flow's resolve / dispatch sub-steps under its
# provisioning part. Neutral opt-in; the flow does not name its consumer.
# Installs its own EXIT trap, which is why the temp file below is removed
# explicitly rather than by a second (trap-replacing) handler of ours.
timing_init "provision-files"

export CA_INVENTORY_VAULT=VmProvisioner
export CA_CONSUMER_ROOT

# The per-host `files` entries ride as a single play-wide --extra-vars document
# (vm_files_by_host), the same channel and shape the toolchain flow uses for its
# resolved pins. Read the inventory vault directly rather than reusing the copy
# the bridge reads: translation has to happen before dispatch, and a second
# read is one pwsh round-trip against a step that then runs unattended for
# minutes.
# Local form to write and remove, controller form to hand the playbook; see
# _create-controller-tempfile.sh for why they differ.
files_vars="$(create_controller_tempfile vm-files-vars)"
# shellcheck disable=SC2310  # predicate in `if`; the failure is handled here
if ! files_vars_ctl="$(resolve_controller_path "${files_vars}")"; then
    rm -f "${files_vars}"
    log_err "cannot express ${files_vars} for the WSL controller (cause above)"
    exit 1
fi

log_info "Resolving file entries (vault read + controller path translation) ..."
timing_span_begin "resolve file entries"
if ! "${common_ansible_root}/ops/_read-vault-config.sh" \
        "VmProvisioner" "VmProvisionerConfig-${SECRET_SUFFIX}" \
        | "${script_dir}/_resolve-vm-files-config.sh" > "${files_vars}"; then
    timing_span_end --failed
    rm -f "${files_vars}"
    log_err "could not resolve the files desired-state (cause above)"
    exit 1
fi
timing_span_end

dispatch_rc=0
# shellcheck disable=SC2310  # rc captured on purpose so the temp file is removed either way
dispatch_playbook \
    playbooks/provision-files.yml \
    --extra-vars "@${files_vars_ctl}" \
    "$@" || dispatch_rc=$?
rm -f "${files_vars}"
exit "${dispatch_rc}"
