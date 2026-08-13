#!/usr/bin/env bats
# Tests for hyper-v/ubuntu/Ansible/ops/provision-env.sh - the operator entry
# point for the Ansible environment variable flow.
#
# This wrapper is contract plus dispatch, so what is asserted here is exactly
# that: which playbook is dispatched, which CA_* contract the bridge is handed,
# and - the assertion with real content - that the flow reads NO vault of its
# own. That absence is the whole design difference from provision-files.sh: the
# files wrapper reads the vault because it must reshape config and rewrite
# Windows paths to /mnt before the controller can open them, and `envVars`
# values need neither. A future edit that "helpfully" adds a vault read and a
# temp document would reintroduce the two-spelling handoff bug that flow shipped
# twice, in a flow that has no reason to be exposed to it.
#
# The shared dispatch tail (_dispatch-playbook.sh) and the controller-path
# handoff have their own suites and are not re-tested here; the bridge is
# stubbed, so this suite is about argument plumbing, not about its behaviour.
# Run with: bats Tests/Ansible/ops/provision-env.bats

# shellcheck source=Tests/Ansible/ops/_bats-helpers.sh
source "${BATS_TEST_DIRNAME}/_bats-helpers.sh"

OPS_DIR="$(cd "${BATS_TEST_DIRNAME}/../../../hyper-v/ubuntu/Ansible/ops" && pwd)"

setup() {
    _bats_init_temp provision-env

    # Copy the real ops/ tree so the wrapper sources its genuine siblings (the
    # dispatch tail is what carries the playbook path through), then displace
    # nothing: unlike the files flow there is no sibling here that would reach
    # outside the sandbox.
    cp -r "${OPS_DIR}" "${TEST_TMP}/ops"

    # Fake Common-Ansible: a bridge that records the argv it was handed instead
    # of running ansible, and a vault reader that FAILS if anything calls it -
    # see the "reads no vault" case below.
    mkdir -p "${TEST_TMP}/Common-Ansible/ops"
    cat >"${TEST_TMP}/Common-Ansible/ops/_read-vault-config.sh" <<STUB
#!/usr/bin/env bash
touch "${TEST_TMP}/vault-was-read"
echo '[]'
STUB
    cat >"${TEST_TMP}/Common-Ansible/ops/_run-playbook.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${TEST_TMP}/playbook-args"
exit 0
STUB
    chmod +x "${TEST_TMP}/Common-Ansible/ops/_read-vault-config.sh" \
             "${TEST_TMP}/Common-Ansible/ops/_run-playbook.sh"

    export COMMON_ANSIBLE_ROOT="${TEST_TMP}/Common-Ansible"
    export SECRET_SUFFIX=Test
}

teardown() {
    _bats_cleanup_temp
}

@test "SECRET_SUFFIX unset fails before anything is dispatched" {
    run env -u SECRET_SUFFIX "${BASH_BIN}" "${TEST_TMP}/ops/provision-env.sh"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"SECRET_SUFFIX"* ]]
    [ ! -f "${TEST_TMP}/playbook-args" ]
}

@test "dispatches the environment variable playbook" {
    run "${BASH_BIN}" "${TEST_TMP}/ops/provision-env.sh"
    [ "${status}" -eq 0 ]
    grep -q 'playbooks/provision-env.yml' "${TEST_TMP}/playbook-args"
}

@test "reads no vault of its own and hands over no extra-vars document" {
    # The design assertion. The desired-state rides in the whole-config document
    # the bridge already surfaces (vm_provisioner_config), so a vault read here
    # would be a second pwsh.exe round trip for data the play already has - and
    # the temp document it would need is the piece that has to be spelled twice
    # across the bridge's WSL re-exec.
    run "${BASH_BIN}" "${TEST_TMP}/ops/provision-env.sh"
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/vault-was-read" ]

    # Through `run` rather than a bare `! grep`: a negated command that is not
    # the last in a bats test does not fail it, and a later case appended below
    # this one would silently disarm the assertion.
    run grep -q -- '--extra-vars' "${TEST_TMP}/playbook-args"
    [ "${status}" -ne 0 ]
}

@test "declares the consumer contract the bridge parses" {
    # CA_INVENTORY_VAULT is the one REQUIRED contract var, and this flow
    # deliberately does NOT ask for a host file server - it transfers no payload
    # at all.
    cat >"${TEST_TMP}/Common-Ansible/ops/_run-playbook.sh" <<STUB
#!/usr/bin/env bash
{
  echo "CA_INVENTORY_VAULT=\${CA_INVENTORY_VAULT:-}"
  echo "CA_CONSUMER_ROOT=\${CA_CONSUMER_ROOT:-}"
  echo "CA_NEEDS_HOST_FILE_SERVER=\${CA_NEEDS_HOST_FILE_SERVER:-UNSET}"
} > "${TEST_TMP}/contract"
exit 0
STUB
    chmod +x "${TEST_TMP}/Common-Ansible/ops/_run-playbook.sh"

    run "${BASH_BIN}" "${TEST_TMP}/ops/provision-env.sh"
    [ "${status}" -eq 0 ]
    grep -q '^CA_INVENTORY_VAULT=VmProvisioner$' "${TEST_TMP}/contract"
    grep -q '^CA_NEEDS_HOST_FILE_SERVER=UNSET$'  "${TEST_TMP}/contract"
    grep -q "^CA_CONSUMER_ROOT=${TEST_TMP}\$"    "${TEST_TMP}/contract"
}

@test "forwards operator args through to the playbook" {
    run "${BASH_BIN}" "${TEST_TMP}/ops/provision-env.sh" --check --limit ubuntu-02-ci
    [ "${status}" -eq 0 ]
    grep -q -- '--check'      "${TEST_TMP}/playbook-args"
    grep -q -- '--limit'      "${TEST_TMP}/playbook-args"
    grep -q -- 'ubuntu-02-ci' "${TEST_TMP}/playbook-args"
}

@test "a failed playbook takes the wrapper's exit code with it" {
    # The dispatch is the wrapper's last statement, so the code propagates by
    # construction - which is precisely why it is worth pinning: a later edit
    # that appends any cleanup after it would silently swallow the failure and
    # report a red run as green to the menu and to E2E.
    cat >"${TEST_TMP}/Common-Ansible/ops/_run-playbook.sh" <<'STUB'
#!/usr/bin/env bash
exit 4
STUB
    chmod +x "${TEST_TMP}/Common-Ansible/ops/_run-playbook.sh"

    run "${BASH_BIN}" "${TEST_TMP}/ops/provision-env.sh"
    [ "${status}" -eq 4 ]
}
