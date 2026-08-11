#!/usr/bin/env bats
# Tests for hyper-v/ubuntu/Ansible/ops/_create-controller-tempfile.sh - the
# helper that keeps a wrapper's temp document readable after the
# Common-Ansible bridge re-execs into WSL.
#
# The regression these guard: provision-files.sh used a plain `mktemp`, whose
# Git Bash result (/tmp/x) names nothing under WSL, so ansible-playbook aborted
# with "Could not find or access ... on the Ansible Controller". The first fix
# keyed on TEMP being drive-qualified, which ALSO failed - MSYS rewrites TEMP
# to /tmp on entry, so the Git Bash branch never fired under the menu. Hence
# the uname test, and hence the stub below: the Windows branch has to be
# exercised on a Linux runner, where uname and cygpath must both be faked.
# Run with: bats Tests/Ansible/ops/_create-controller-tempfile.bats

SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../../../hyper-v/ubuntu/Ansible/ops" && pwd)/_create-controller-tempfile.sh"

# shellcheck source=Tests/Ansible/ops/_bats-helpers.sh
source "${BATS_TEST_DIRNAME}/_bats-helpers.sh"

setup() {
    _bats_resolve_bash
    TEST_TMP="$(mktemp -d -t create-controller-tempfile.XXXXXX)"
    mkdir -p "${TEST_TMP}/stubs"
}

teardown() {
    _bats_cleanup_temp
}

# Stand up a Git Bash impersonation: uname reports MINGW and cygpath maps a
# POSIX path onto the Windows temp dir the real one would report. Prepending
# the stub dir to PATH is how the substrate's own bridge suite fakes the same
# launch, so both repos exercise the Windows branch the same way.
install_mingw_stubs() {
    cat >"${TEST_TMP}/stubs/uname" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "-s" ]]; then echo "MINGW64_NT-10.0-26200"; else exec /usr/bin/uname "$@"; fi
STUB
    cat >"${TEST_TMP}/stubs/cygpath" <<'STUB'
#!/usr/bin/env bash
# Real cygpath -w resolves an MSYS path through the mount table; the mapping
# that matters here is /tmp -> the Windows temp dir, spelled with backslashes.
printf 'C:\\Users\\tester\\AppData\\Local\\Temp%s\n' "${2#/tmp}" | tr '/' '\\'
STUB
    chmod +x "${TEST_TMP}/stubs/uname" "${TEST_TMP}/stubs/cygpath"
}

@test "sourcing defines both handoff verbs" {
    source "${SCRIPT}"
    declare -F create_controller_tempfile >/dev/null
    declare -F resolve_controller_path >/dev/null
}

@test "creates a real file the caller can write to" {
    run "${BASH_BIN}" -c '
        source "$1"
        path="$(create_controller_tempfile vm-files-vars)" || exit 1
        echo probe > "${path}" || exit 1
        printf "%s" "${path}"
    ' _ "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [ -f "${output}" ]
    rm -f "${output}"
}

@test "the controller-side file keeps mktemp's owner-only mode" {
    # Guards against a future -u / explicit-mode change loosening this. It
    # asserts the CONTROLLER side only, which is where bats runs: under MSYS
    # the same call yields 0644 and no chmod can fix it, so the Windows side
    # relies on the per-user temp directory's ACL instead. Asserting 600
    # unconditionally would claim a protection Git Bash does not have.
    run "${BASH_BIN}" -c '
        source "$1"
        create_controller_tempfile vm-files-vars
    ' _ "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [ "$(stat -c '%a' "${output}")" = "600" ]
    rm -f "${output}"
}

@test "honours the caller's name prefix" {
    # The prefix is what makes a leaked temp file traceable to its flow.
    run "${BASH_BIN}" -c '
        source "$1"
        create_controller_tempfile some-other-flow
    ' _ "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"/some-other-flow."* ]]
    rm -f "${output}"
}

@test "two calls return distinct paths" {
    run "${BASH_BIN}" -c '
        source "$1"
        a="$(create_controller_tempfile vm-files-vars)"
        b="$(create_controller_tempfile vm-files-vars)"
        rm -f "${a}" "${b}"
        [ "${a}" != "${b}" ]
    ' _ "${SCRIPT}"
    [ "${status}" -eq 0 ]
}

@test "a controller-side path resolves to itself" {
    # WSL and native-Linux CI: /tmp is already the controller's own, so the
    # helper must not touch it. This is the path E2E takes.
    run "${BASH_BIN}" -c '
        source "$1"
        resolve_controller_path /tmp/vm-files-vars.abc123
    ' _ "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "/tmp/vm-files-vars.abc123" ]
}

@test "a Git Bash path resolves to its /mnt spelling" {
    # The defect in one assertion: under a MINGW uname the POSIX path must
    # come back as something the WSL controller can open.
    install_mingw_stubs
    run env PATH="${TEST_TMP}/stubs:${PATH}" "${BASH_BIN}" -c '
        source "$1"
        resolve_controller_path /tmp/vm-files-vars.abc123
    ' _ "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "/mnt/c/Users/tester/AppData/Local/Temp/vm-files-vars.abc123" ]
}

@test "the created path round-trips through resolve under Git Bash" {
    # Composition is the real contract - neither verb is useful alone, and
    # testing them apart is what let the TEMP-keyed version pass while broken.
    install_mingw_stubs
    run env PATH="${TEST_TMP}/stubs:${PATH}" "${BASH_BIN}" -c '
        source "$1"
        path="$(create_controller_tempfile vm-files-vars)" || exit 1
        resolve_controller_path "${path}" || exit 1
        rm -f "${path}"
    ' _ "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == "/mnt/c/Users/tester/AppData/Local/Temp/vm-files-vars."* ]]
}

@test "a missing cygpath fails loudly rather than returning a bad path" {
    # Without cygpath there is no honest translation, and silently handing back
    # the POSIX path is exactly the original defect.
    cat >"${TEST_TMP}/stubs/uname" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "-s" ]]; then echo "MINGW64_NT-10.0-26200"; else exec /usr/bin/uname "$@"; fi
STUB
    chmod +x "${TEST_TMP}/stubs/uname"
    # A PATH with the stub uname but no cygpath anywhere on it.
    run env PATH="${TEST_TMP}/stubs:/usr/bin:/bin" "${BASH_BIN}" -c '
        source "$1"
        resolve_controller_path /tmp/vm-files-vars.abc123
    ' _ "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"cygpath"* ]]
}

@test "an untranslatable Windows path is rejected, not guessed" {
    # cygpath can hand back a UNC path for a network-mounted temp dir; that
    # has no /mnt equivalent, so the failure must surface here.
    cat >"${TEST_TMP}/stubs/uname" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "-s" ]]; then echo "MINGW64_NT-10.0-26200"; else exec /usr/bin/uname "$@"; fi
STUB
    cat >"${TEST_TMP}/stubs/cygpath" <<'STUB'
#!/usr/bin/env bash
printf '\\\\fileserver\\share\\vm-files-vars.abc123\n'
STUB
    chmod +x "${TEST_TMP}/stubs/uname" "${TEST_TMP}/stubs/cygpath"
    run env PATH="${TEST_TMP}/stubs:${PATH}" "${BASH_BIN}" -c '
        source "$1"
        resolve_controller_path /tmp/vm-files-vars.abc123
    ' _ "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"UNC"* ]]
}
