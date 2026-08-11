#!/usr/bin/env bash
# Shared dispatch tail for this repo's ops/ flow wrappers.
#
# Every wrapper ends the same way: hand a playbook (plus its extra-vars and the
# operator's forwarded args) to the Common-Ansible bridge, and - when the E2E
# orchestrator asked for a timing tree - run it under a span deepened into the
# per-role / per-task children the timing_tree callback emits. That tail is
# flow-agnostic, so it lives here once instead of being re-pasted per wrapper.
#
# Sourced, not executed: it runs against the caller's already-resolved
# common_ansible_root and the timing emitter the caller armed with timing_init.
#
# The caller keeps ownership of what surrounds the dispatch (vault reads,
# staging, temp files) because those differ per flow - only the dispatch itself
# is common.

# common_ansible_root and the timing_* verbs are provided by the sourcing
# wrapper (imports/_common-ansible-root.sh, imports/_timing.sh). shellcheck
# cannot follow a source through a runtime-resolved root, so declare the
# intentional external references once here rather than inlining the helper
# back into each wrapper to silence it.
# shellcheck disable=SC2154

# The rows file below has to be readable from BOTH this shell and the WSL
# controller the bridge may re-exec into, so the tail owns the handoff helpers
# rather than relying on its callers to have sourced them.
# shellcheck source=hyper-v/ubuntu/Ansible/ops/_create-controller-tempfile.sh
source "${BASH_SOURCE[0]%/*}/_create-controller-tempfile.sh"

# dispatch_playbook <playbook-path-relative-to-CA_CONSUMER_ROOT> [args...]
#
# Returns the playbook's exit code. Deliberately not `exec` - the caller may
# hold a temp file that must outlive the dispatch and be removed afterwards,
# and an exec'd process runs neither the caller's cleanup nor the timing
# flush.
dispatch_playbook() {
    local playbook_cmd=("${common_ansible_root}/ops/_run-playbook.sh" "$@")
    local tasks_rows
    local tasks_rows_ctl
    local playbook_rc=0

    # shellcheck disable=SC2310  # predicate in `if`; set -e intentionally relaxed
    if timing_enabled; then
        # Point the timing_tree callback (the bridge enables it when this var
        # is set) at a temp rows file, run, then graft the rows in before the
        # span closes, so the tree shows `run playbook -> Gathering Facts /
        # <role> -> task / ...` instead of one flat bar.
        #
        # Writer and reader sit on opposite sides of a possible WSL re-exec:
        # the callback runs inside ansible-playbook (always the controller),
        # while the graft below runs here (Git Bash when the menu launched the
        # flow). So the file is minted somewhere both can reach and the
        # callback is handed the /mnt form, exactly as the file flow pairs its
        # extra-vars document. A plain mktemp would name a Git Bash /tmp entry
        # the callback cannot open, and the tree would silently lose every
        # child row.
        tasks_rows="$(create_controller_tempfile timing-tasks)"
        # shellcheck disable=SC2310  # predicate in `if`; the failure is handled here
        if ! tasks_rows_ctl="$(resolve_controller_path "${tasks_rows}")"; then
            rm -f "${tasks_rows}"
            log_err "cannot express ${tasks_rows} for the WSL controller (cause above)"
            return 1
        fi
        export TIMING_TASKS_OUTPUT_PATH="${tasks_rows_ctl}"
        timing_span_begin "run playbook"
        "${playbook_cmd[@]}" || playbook_rc=$?
        # Graft before closing the span (a no-op if the callback wrote nothing,
        # e.g. a hard abort before stats). Independent of rc so a failed run
        # still shows how far its tasks got.
        timing_graft_children_from "${tasks_rows}"
        if [[ "${playbook_rc}" -eq 0 ]]; then
            timing_span_end
        else
            timing_span_end --failed
        fi
        rm -f "${tasks_rows}"
        return "${playbook_rc}"
    fi

    "${playbook_cmd[@]}" || playbook_rc=$?
    return "${playbook_rc}"
}
