#!/usr/bin/env bash
# Shared opening for this repo's ops/ flow wrappers - the mirror image of
# _dispatch-playbook.sh, which is the shared closing.
#
# Every wrapper starts the same way: reject a run with no lifecycle selected,
# resolve this repo's Ansible-slice root, pull in the four helpers each of them
# uses, arm the timing emitter, and declare the one CA_* contract value that is
# the same for all of them. Three wrappers carried byte-identical copies of that
# block; this is the one copy.
#
# Sourced, not executed, and it deliberately runs its steps in the caller's
# shell rather than defining a verb the caller invokes: half of what it does IS
# leaving state behind (the sourced helpers' functions, common_ansible_root,
# CA_CONSUMER_ROOT), which a function boundary would only obscure.
#
# Two caller-set inputs, the same contract _dispatch-playbook.sh uses:
#
#   script_dir  the calling wrapper's own directory, already resolved. Taken
#               rather than re-derived because the caller must resolve it
#               anyway to find THIS file, and because BASH_SOURCE indexing
#               across a source boundary is the kind of cleverness that breaks
#               silently when a wrapper grows a second source layer.
#   flow_name   the flow's label for the timing tree (e.g. provision-files).
#
# Neither is visible to the linter across the source boundary, hence the
# blanket disable below. The alternative is inlining this file back into three
# wrappers, which is the duplication it exists to undo.
#
# (A comment line here must not begin with the linter's own name, or it is
# parsed as a malformed directive and the whole file stops being followed -
# which silently re-flags every var the wrappers get from here.)
# shellcheck disable=SC2154

# Before anything is sourced, so the failure is one clear message rather than
# an opaque empty-suffix error deeper in - inside the bridge's vault read, or
# inside whatever desired-state read a given wrapper does first. Raw echo
# rather than log_err precisely because the logger is not loaded yet: loading
# it first would put a resolvable-sibling-checkout requirement in front of a
# check that needs nothing but an environment variable.
#
# `exit` from a sourced file exits the caller, which is the intent - this is a
# precondition for the whole run, not advice.
if [[ -z "${SECRET_SUFFIX:-}" ]]; then
    echo "SECRET_SUFFIX must be set (e.g. Production or the caller's lifecycle label)" >&2
    exit 2
fi

# This repo's Ansible-slice root (ops/ -> Ansible/): the consumer root the
# bridge resolves the playbook - and, for the toolchain flow, its extra-vars
# fragment - from, while the reusable roles resolve from the sibling checkout.
CA_CONSUMER_ROOT="$(cd "${script_dir}/.." && pwd)"

# shellcheck source=hyper-v/ubuntu/Ansible/ops/imports/_log.sh
source "${script_dir}/imports/_log.sh"
# shellcheck source=hyper-v/ubuntu/Ansible/ops/imports/_common-ansible-root.sh
source "${script_dir}/imports/_common-ansible-root.sh"
# shellcheck source=hyper-v/ubuntu/Ansible/ops/imports/_timing.sh
source "${script_dir}/imports/_timing.sh"
# Pulls in _create-controller-tempfile.sh transitively, which is why a wrapper
# needing the raw handoff verbs still sources that file explicitly: a direct
# dependency stated through someone else's transitive one is a dependency that
# disappears the day the middle file stops needing it.
# shellcheck source=hyper-v/ubuntu/Ansible/ops/_dispatch-playbook.sh
source "${script_dir}/_dispatch-playbook.sh"

# Arm the timing emitter (a no-op unless TIMING_TREE_OUTPUT_PATH is set) so the
# E2E orchestrator can graft this flow's sub-steps under its provisioning part.
# Neutral opt-in; no flow names its consumer.
timing_init "${flow_name}"

# The one contract value every flow in this repo shares: the vault holding the
# fleet inventory, which is also where each flow's desired-state lives. What
# each flow declares BEYOND this differs (the file server, extra vaults), so
# those stay with the wrapper that needs them.
export CA_INVENTORY_VAULT=VmProvisioner
export CA_CONSUMER_ROOT
