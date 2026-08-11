#!/usr/bin/env bash
# Harness for running this repo's Ansible playbooks under bats.
#
# The playbooks carry rules of their own - selection out of the fleet config,
# and the wrapper-shape checks the substrate roles cannot own because they
# never see the wrapper object. Nothing else in this repo's test surface can
# reach them: the ops/ bats suites stub the bridge out before ansible is ever
# invoked, and ansible-lint only parses. So this harness runs the real playbook
# against a fixture fleet and reads back what it did.
#
# Three deliberate choices, each of which is what makes the runs cheap and
# hermetic enough to sit in a unit suite:
#
#   - The SUBSTRATE ROLES ARE STUBBED. They have their own molecule coverage in
#     Common-Ansible, and a play test that reconciled a real /etc/environment
#     would be testing them again - on the controller's own filesystem, as root.
#     The stubs instead REPORT the vars they were handed, which turns "did the
#     play select and unwrap the right thing for this host" into a greppable
#     line. What is under test is the play, and the play's whole job is to hand
#     those roles the right inputs.
#   - Connection is local and facts are off, so no VM, container or SSH is
#     involved. The play gathers no facts and its tasks are action plugins that
#     execute on the controller, so there is nothing left needing a target.
#   - The fleet config arrives the way the bridge delivers it in production - a
#     `vm_provisioner_config` extra-vars document - so a test feeds the play the
#     same shape an operator's vault holds.
#
# ansible-playbook comes from the shared Common-Ansible controller venv, the
# same toolchain scripts/run-lint-ansible.sh reuses; this repo owns no venv.
# When that sibling checkout is absent - CI checks out only this repo - the
# suite SKIPS rather than fails, which is the honest outcome: these cases are a
# local pre-push gate, and a red run for a missing sibling would train everyone
# to ignore it. COMMON_ANSIBLE_ROOT overrides the sibling default.

# Absolute repo root, from this file's own location (Tests/Ansible/playbooks).
#
# BATS_TEST_DIRNAME is exported by bats into the suite and into every file the
# suite sources, which the linter cannot see across that boundary. Anchoring on
# it rather than on BASH_SOURCE keeps one rule for where the repo root is: the
# suites already resolve fixtures that way.
# shellcheck disable=SC2154
_ph_repo_root() {
    (cd "${BATS_TEST_DIRNAME}/../../.." && pwd)
}

# Locate ansible-playbook, preferring the shared controller venv over whatever
# is on PATH so a local run uses the pinned toolchain CI's lint gate uses.
# Prints the path; returns 1 when neither is available.
_ph_find_ansible_playbook() {
    local repo_root ca_root candidate
    repo_root="$(_ph_repo_root)"
    ca_root="${COMMON_ANSIBLE_ROOT:-$(cd "${repo_root}/.." && pwd)/Common-Ansible}"

    candidate="${ca_root}/.venv/bin/ansible-playbook"
    if [[ -x "${candidate}" ]]; then
        printf '%s\n' "${candidate}"
        return 0
    fi
    if command -v ansible-playbook >/dev/null 2>&1; then
        command -v ansible-playbook
        return 0
    fi
    return 1
}

# Stand up the fixture estate: a temp dir, an inventory whose group is the one
# the plays bind to, and no-op roles that echo the vars they were called with.
#
# Callers pass the inventory hostnames. They must match the `vmName` values in
# the config a test feeds, because matching those two is precisely the
# selection the play performs.
_ph_init_temp() {
    local prefix="$1"
    shift

    TEST_TMP="$(mktemp -d -t "${prefix}.XXXXXX")"
    export TEST_TMP

    # The bridge drops every reachable VM into this group; the plays bind to it.
    {
        echo "[vm_provisioner_hosts]"
        local host
        for host in "$@"; do
            echo "${host} ansible_connection=local"
        done
    } >"${TEST_TMP}/inventory.ini"

    _ph_install_stub_role vm_env_vars \
        "VM_ENV_VARS_IN host={{ inventory_hostname }} block={{ vm_env_vars_block_name }} count={{ vm_env_vars_entries | length }} names={{ vm_env_vars_entries | map(attribute='name') | join(',') }}"
    _ph_install_stub_role env_vars_report \
        "ENV_VARS_REPORT_RAN host={{ inventory_hostname }}"
}

# One stub role: a single debug task emitting the caller's marker template.
# Deliberately not `assert`-based - a stub that can fail would compete with the
# play's own rules for the reason a case went red.
_ph_install_stub_role() {
    local name="$1" marker="$2"
    mkdir -p "${TEST_TMP}/roles/${name}/tasks"
    {
        echo "---"
        echo "- name: Report the vars ${name} was handed"
        echo "  ansible.builtin.debug:"
        echo "    msg: \"${marker}\""
    } >"${TEST_TMP}/roles/${name}/tasks/main.yml"
}

_ph_cleanup_temp() {
    rm -rf "${TEST_TMP}"
}

# Run a playbook against the fixture estate.
#   _ph_run_playbook <playbook-relative-to-Ansible-slice> <config-json> [args...]
#
# The config JSON is the `vm_provisioner_config` VALUE (the fleet array); it is
# wrapped into an extra-vars document here so a test writes only the part it
# cares about. Runs from TEST_TMP so the repo's own ansible.cfg is out of the
# picture and every setting a case depends on is explicit below.
_ph_run_playbook() {
    local playbook="$1" config_json="$2"
    shift 2

    local repo_root ansible_playbook
    repo_root="$(_ph_repo_root)"
    ansible_playbook="$(_ph_find_ansible_playbook)"

    printf '{"vm_provisioner_config": %s}\n' "${config_json}" \
        >"${TEST_TMP}/extra-vars.json"

    (
        cd "${TEST_TMP}" || exit 1
        # Only the stub roles are resolvable, so a play that grew a dependency
        # on a real substrate role fails loudly here instead of silently
        # picking one up from the sibling checkout.
        export ANSIBLE_ROLES_PATH="${TEST_TMP}/roles"
        # Plain, uncoloured, un-decorated output: every assertion in the suite
        # is a grep over it.
        export ANSIBLE_STDOUT_CALLBACK=default
        export ANSIBLE_NOCOLOR=1
        export ANSIBLE_FORCE_COLOR=0
        export ANSIBLE_DEPRECATION_WARNINGS=False
        export ANSIBLE_RETRY_FILES_ENABLED=False
        "${ansible_playbook}" \
            -i "${TEST_TMP}/inventory.ini" \
            --extra-vars "@${TEST_TMP}/extra-vars.json" \
            "${repo_root}/hyper-v/ubuntu/Ansible/${playbook}" \
            "$@" 2>&1
    )
}

# Skip the calling test when the controller venv is absent. Called per test
# rather than in setup() so the reason is attached to each skipped case.
_ph_require_ansible() {
    if ! _ph_find_ansible_playbook >/dev/null; then
        skip "ansible-playbook unavailable (needs the Common-Ansible sibling checkout's .venv)"
    fi
}
