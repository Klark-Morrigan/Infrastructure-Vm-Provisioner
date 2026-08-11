#!/usr/bin/env bats
# Tests for hyper-v/ubuntu/Ansible/playbooks/provision-env.yml.
#
# The play owns two things no role and no wrapper can be tested for:
#
#   - SELECTION. Which VM's `envVars` reaches which host, unwrapped into the
#     two vars vm_env_vars takes. Get it wrong and a host quietly receives
#     another host's variables, or none.
#   - THE WRAPPER-SHAPE RULE. Assert-VmEnvVarsField validates the `envVars`
#     object whole, including its own sub-field set; vm_env_vars never sees the
#     wrapper, so those rules live in the play. The failure they prevent is the
#     worst kind available here: `entrys` for `entries` selects nothing, hands
#     the role an empty entry list beside a valid block name, and produces a
#     green run that RETRACTS the block it was asked to write.
#
# The substrate roles are stubbed and report their inputs - see
# _bats-playbook-helpers.sh for why, and for the skip when the shared
# Common-Ansible controller venv is absent.
# Run with: bats Tests/Ansible/playbooks/provision-env.bats

# shellcheck source=Tests/Ansible/playbooks/_bats-playbook-helpers.sh
source "${BATS_TEST_DIRNAME}/_bats-playbook-helpers.sh"

setup() {
    _ph_init_temp provision-env-play ubuntu-01-ci ubuntu-02-ci
}

teardown() {
    _ph_cleanup_temp
}

run_play() {
    run _ph_run_playbook playbooks/provision-env.yml "$@"
}

# ---------------------------------------------------------------------------
# Selection: config in, role vars out
# ---------------------------------------------------------------------------

@test "a declared block reaches the role as its block name and entries" {
    _ph_require_ansible
    run_play '[{"vmName": "ubuntu-02-ci",
                "envVars": {"blockName": "ci-jars",
                            "entries": [{"name": "STARSECTOR_HOME",
                                         "value": "/opt/ci-jars/starsector"}]}}]'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"VM_ENV_VARS_IN host=ubuntu-02-ci block=ci-jars count=1 names=STARSECTOR_HOME"* ]]
}

@test "each host gets its own block and never its neighbour's" {
    # The selection defect that would be invisible in a single-VM fixture:
    # a play-var expression that ignored inventory_hostname would hand both
    # hosts whichever entry sorted first.
    _ph_require_ansible
    run_play '[{"vmName": "ubuntu-01-ci",
                "envVars": {"blockName": "app-runtime",
                            "entries": [{"name": "APP_HOME", "value": "/opt/app"}]}},
               {"vmName": "ubuntu-02-ci",
                "envVars": {"blockName": "ci-jars",
                            "entries": [{"name": "STARSECTOR_HOME", "value": "/opt/ci"}]}}]'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"VM_ENV_VARS_IN host=ubuntu-01-ci block=app-runtime count=1 names=APP_HOME"* ]]
    [[ "${output}" == *"VM_ENV_VARS_IN host=ubuntu-02-ci block=ci-jars count=1 names=STARSECTOR_HOME"* ]]
}

@test "a host with no config entry at all is a no-op, not an error" {
    # The bridge groups every reachable VM; a fleet member the config never
    # mentions must not fail the run for the hosts that are declared.
    _ph_require_ansible
    run_play '[{"vmName": "ubuntu-02-ci",
                "envVars": {"blockName": "ci-jars",
                            "entries": [{"name": "A", "value": "b"}]}}]'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"VM_ENV_VARS_IN host=ubuntu-01-ci block= count=0 names="* ]]
}

@test "a VM declaring no envVars hands the role the empty no-op input" {
    _ph_require_ansible
    run_play '[{"vmName": "ubuntu-02-ci", "files": []}]'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"VM_ENV_VARS_IN host=ubuntu-02-ci block= count=0 names="* ]]
}

@test "an empty entries list keeps its block name - retraction, not no-op" {
    # THE distinction the whole flow turns on. Both this and the case above
    # hand the role zero entries; only this one carries a block name, and that
    # is the entire difference between "remove this block" and "do nothing".
    _ph_require_ansible
    run_play '[{"vmName": "ubuntu-02-ci",
                "envVars": {"blockName": "ci-jars", "entries": []}}]'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"VM_ENV_VARS_IN host=ubuntu-02-ci block=ci-jars count=0 names="* ]]
}

@test "the report role runs after the reconcile" {
    _ph_require_ansible
    run_play '[{"vmName": "ubuntu-02-ci",
                "envVars": {"blockName": "ci-jars",
                            "entries": [{"name": "A", "value": "b"}]}}]'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"ENV_VARS_REPORT_RAN host=ubuntu-02-ci"* ]]
}

# ---------------------------------------------------------------------------
# The wrapper-shape rule
# ---------------------------------------------------------------------------

@test "an unknown sub-field is rejected and named" {
    # The retraction-by-typo scenario. Without the rule this run is GREEN and
    # the role is told to remove ci-jars.
    _ph_require_ansible
    run_play '[{"vmName": "ubuntu-02-ci",
                "envVars": {"blockName": "ci-jars", "entrys": []}}]'
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"ubuntu-02-ci"* ]]
    [[ "${output}" == *"entrys"* ]]
    # The role must never have been reached for that host.
    [[ "${output}" != *"VM_ENV_VARS_IN host=ubuntu-02-ci"* ]]
}

@test "a missing required sub-field is rejected" {
    _ph_require_ansible
    run_play '[{"vmName": "ubuntu-02-ci", "envVars": {"entries": []}}]'
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Declared: entries"* ]]
}

@test "an envVars that is a string is rejected, and the message survives it" {
    # The hazard the `is mapping` guard on the diagnostic play vars exists for:
    # `assert` renders fail_msg on EVERY run, so a .keys() call inline in the
    # message would abort here with a filter error about the message itself
    # instead of the operator's actual mistake.
    _ph_require_ansible
    run_play '[{"vmName": "ubuntu-02-ci", "envVars": "ci-jars"}]'
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"(not an object)"* ]]
    [[ "${output}" != *"template error"* ]]
}

@test "an envVars that is a list is rejected, and the message survives it" {
    _ph_require_ansible
    run_play '[{"vmName": "ubuntu-02-ci",
                "envVars": [{"name": "A", "value": "b"}]}]'
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"(not an object)"* ]]
    [[ "${output}" != *"template error"* ]]
}

@test "an explicitly empty envVars object is legal and skips the rule" {
    _ph_require_ansible
    run_play '[{"vmName": "ubuntu-02-ci", "envVars": {}}]'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"VM_ENV_VARS_IN host=ubuntu-02-ci block= count=0 names="* ]]
}

@test "the rule still fires under a targeted --tags run" {
    # It is tagged `always` because iterating on this config with
    # --tags vm_env_vars is exactly when the typo is most likely to exist.
    _ph_require_ansible
    run_play '[{"vmName": "ubuntu-02-ci",
                "envVars": {"blockName": "ci-jars", "entrys": []}}]' \
        --tags vm_env_vars
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"entrys"* ]]
}

@test "one host's malformed declaration does not stop the others" {
    # any_errors_fatal is false, so the valid host is still reconciled - the
    # operator gets both the rejection and the work that could be done.
    _ph_require_ansible
    run_play '[{"vmName": "ubuntu-01-ci",
                "envVars": {"blockName": "app-runtime",
                            "entries": [{"name": "APP_HOME", "value": "/opt/app"}]}},
               {"vmName": "ubuntu-02-ci",
                "envVars": {"blockName": "ci-jars", "entrys": []}}]'
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"VM_ENV_VARS_IN host=ubuntu-01-ci block=app-runtime count=1"* ]]
    [[ "${output}" == *"entrys"* ]]
}
