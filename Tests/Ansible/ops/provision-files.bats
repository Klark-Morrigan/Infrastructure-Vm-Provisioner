#!/usr/bin/env bats
# Tests for hyper-v/ubuntu/Ansible/ops/provision-files.sh - the operator entry
# point for the Ansible file flow. These are WIRING tests: the pieces the
# wrapper composes have their own unit suites, so what is asserted here is the
# thing no unit test can see - which of the two path forms actually reaches
# ansible-playbook.
#
# That is the gap the flow shipped through twice. Both defects left every unit
# suite green: the wrapper handed --extra-vars a path minted in the launching
# shell's dialect, and the bridge's WSL re-exec forwards args verbatim, so the
# controller opened nothing. Asserting the recorded argv closes it.
#
# The bridge, the vault read and the reshape are all stubbed - this suite is
# about argument plumbing, not about any of their behaviour.
# Run with: bats Tests/Ansible/ops/provision-files.bats

# shellcheck source=Tests/Ansible/ops/_bats-helpers.sh
source "${BATS_TEST_DIRNAME}/_bats-helpers.sh"

OPS_DIR="$(cd "${BATS_TEST_DIRNAME}/../../../hyper-v/ubuntu/Ansible/ops" && pwd)"

setup() {
    _bats_init_temp provision-files
    mkdir -p "${TEST_TMP}/stubs"

    # Copy the real ops/ tree so the wrapper sources its genuine siblings
    # (the handoff helpers and the dispatch tail are what is under test),
    # then displace only the two that would reach outside the sandbox.
    cp -r "${OPS_DIR}" "${TEST_TMP}/ops"

    cat >"${TEST_TMP}/ops/_resolve-vm-files-config.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
echo '{"vm_files_by_host":{"ubuntu-01-ci":[]}}'
STUB
    chmod +x "${TEST_TMP}/ops/_resolve-vm-files-config.sh"

    # Fake Common-Ansible: a vault reader that emits a fleet, and a bridge
    # that records the argv it was handed instead of running ansible.
    mkdir -p "${TEST_TMP}/Common-Ansible/ops"
    cat >"${TEST_TMP}/Common-Ansible/ops/_read-vault-config.sh" <<'STUB'
#!/usr/bin/env bash
echo '[{"vmName":"ubuntu-01-ci","files":[]}]'
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

# Impersonate Git Bash: the menu's launcher, and the only side where the two
# path forms differ. Same stubbing the handoff helper's own suite uses.
install_mingw_stubs() {
    cat >"${TEST_TMP}/stubs/uname" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "-s" ]]; then echo "MINGW64_NT-10.0-26200"; else exec /usr/bin/uname "$@"; fi
STUB
    cat >"${TEST_TMP}/stubs/cygpath" <<'STUB'
#!/usr/bin/env bash
printf 'C:\\Users\\tester\\AppData\\Local\\Temp%s\n' "${2#/tmp}" | tr '/' '\\'
STUB
    chmod +x "${TEST_TMP}/stubs/uname" "${TEST_TMP}/stubs/cygpath"
}

# The recorder writes one argv element per line, so the document is the line
# after the --extra-vars flag. -A1 must precede the -- that ends option
# parsing, or grep reads it as a filename.
extra_vars_arg() {
    grep -A1 -- '--extra-vars' "${TEST_TMP}/playbook-args" | tail -n1
}

@test "SECRET_SUFFIX unset fails before anything is dispatched" {
    run env -u SECRET_SUFFIX "${BASH_BIN}" "${TEST_TMP}/ops/provision-files.sh"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"SECRET_SUFFIX"* ]]
    [ ! -f "${TEST_TMP}/playbook-args" ]
}

@test "dispatches the file playbook with an extra-vars document" {
    run "${BASH_BIN}" "${TEST_TMP}/ops/provision-files.sh"
    [ "${status}" -eq 0 ]
    grep -q 'playbooks/provision-files.yml' "${TEST_TMP}/playbook-args"
    grep -q -- '--extra-vars' "${TEST_TMP}/playbook-args"
}

@test "under Git Bash the extra-vars path is the controller form, not the local one" {
    # THE regression. A /tmp/... path here is the exact bug that reached the
    # operator twice: it names nothing once the bridge re-execs into WSL.
    install_mingw_stubs
    run env PATH="${TEST_TMP}/stubs:${PATH}" "${BASH_BIN}" "${TEST_TMP}/ops/provision-files.sh"
    [ "${status}" -eq 0 ]

    arg="$(extra_vars_arg)"
    [[ "${arg}" == "@/mnt/c/Users/tester/AppData/Local/Temp/vm-files-vars."* ]]
    [[ "${arg}" != "@/tmp/"* ]]
}

@test "on the controller the extra-vars path is left alone" {
    # WSL / native-Linux CI - the path E2E takes. No translation should
    # happen, so a /mnt prefix here would be just as wrong.
    run "${BASH_BIN}" "${TEST_TMP}/ops/provision-files.sh"
    [ "${status}" -eq 0 ]

    arg="$(extra_vars_arg)"
    [[ "${arg}" == "@/tmp/vm-files-vars."* ]]
    [[ "${arg}" != "@/mnt/"* ]]
}

@test "the document handed over is the one the reshape produced" {
    # Guards the other half of the pairing: the wrapper must WRITE to the
    # local form. Writing to the controller form would leave the dispatched
    # file empty under Git Bash, which no path assertion would catch.
    install_mingw_stubs
    cat >"${TEST_TMP}/Common-Ansible/ops/_run-playbook.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${TEST_TMP}/playbook-args"
# Read back through the LOCAL spelling the harness can open, mirroring what
# the controller would reach through its own.
for a in "\$@"; do
  case "\${a}" in
    @*) cp "/tmp/\${a##*/}" "${TEST_TMP}/dispatched-doc" 2>/dev/null || true ;;
  esac
done
exit 0
STUB
    chmod +x "${TEST_TMP}/Common-Ansible/ops/_run-playbook.sh"

    run env PATH="${TEST_TMP}/stubs:${PATH}" "${BASH_BIN}" "${TEST_TMP}/ops/provision-files.sh"
    [ "${status}" -eq 0 ]
    [ -s "${TEST_TMP}/dispatched-doc" ]
    grep -q 'vm_files_by_host' "${TEST_TMP}/dispatched-doc"
}

@test "the temp document is removed after a successful dispatch" {
    run "${BASH_BIN}" "${TEST_TMP}/ops/provision-files.sh"
    [ "${status}" -eq 0 ]
    leftovers="$(find /tmp -maxdepth 1 -name 'vm-files-vars.*' -print 2>/dev/null || true)"
    [ -z "${leftovers}" ]
}

@test "the temp document is removed when the playbook fails" {
    cat >"${TEST_TMP}/Common-Ansible/ops/_run-playbook.sh" <<'STUB'
#!/usr/bin/env bash
exit 4
STUB
    chmod +x "${TEST_TMP}/Common-Ansible/ops/_run-playbook.sh"

    run "${BASH_BIN}" "${TEST_TMP}/ops/provision-files.sh"
    [ "${status}" -eq 4 ]
    leftovers="$(find /tmp -maxdepth 1 -name 'vm-files-vars.*' -print 2>/dev/null || true)"
    [ -z "${leftovers}" ]
}

@test "a failed reshape aborts before dispatch and leaves no temp document" {
    cat >"${TEST_TMP}/ops/_resolve-vm-files-config.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
echo "reshape boom" >&2
exit 1
STUB
    chmod +x "${TEST_TMP}/ops/_resolve-vm-files-config.sh"

    run "${BASH_BIN}" "${TEST_TMP}/ops/provision-files.sh"
    [ "${status}" -ne 0 ]
    [ ! -f "${TEST_TMP}/playbook-args" ]
    leftovers="$(find /tmp -maxdepth 1 -name 'vm-files-vars.*' -print 2>/dev/null || true)"
    [ -z "${leftovers}" ]
}

@test "declares the consumer contract the bridge parses" {
    # CA_INVENTORY_VAULT is the one REQUIRED contract var, and this flow
    # deliberately does NOT ask for a host file server - copy pushes bytes
    # through the SSH channel the bridge already opened.
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

    run "${BASH_BIN}" "${TEST_TMP}/ops/provision-files.sh"
    [ "${status}" -eq 0 ]
    grep -q '^CA_INVENTORY_VAULT=VmProvisioner$'    "${TEST_TMP}/contract"
    grep -q '^CA_NEEDS_HOST_FILE_SERVER=UNSET$'     "${TEST_TMP}/contract"
    grep -q "^CA_CONSUMER_ROOT=${TEST_TMP}\$"       "${TEST_TMP}/contract"
}

@test "forwards operator args through to the playbook" {
    run "${BASH_BIN}" "${TEST_TMP}/ops/provision-files.sh" --check --limit ubuntu-01-ci
    [ "${status}" -eq 0 ]
    grep -q -- '--check'       "${TEST_TMP}/playbook-args"
    grep -q -- '--limit'       "${TEST_TMP}/playbook-args"
    grep -q -- 'ubuntu-01-ci'  "${TEST_TMP}/playbook-args"
}
