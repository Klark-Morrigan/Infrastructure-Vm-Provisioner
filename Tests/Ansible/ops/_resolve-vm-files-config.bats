#!/usr/bin/env bats
# Tests for hyper-v/ubuntu/Ansible/ops/_resolve-vm-files-config.sh - the
# stdin -> stdout reshape that lifts each VM's `files` array into the
# vm_files_by_host extra-vars document and translates every controller-side
# path on the way. Pure transform; jq is the only external dep, run for real.
# Run with: bats Tests/Ansible/ops/_resolve-vm-files-config.bats

SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../../../hyper-v/ubuntu/Ansible/ops" && pwd)/_resolve-vm-files-config.sh"

# shellcheck source=Tests/Ansible/ops/_bats-helpers.sh
source "${BATS_TEST_DIRNAME}/_bats-helpers.sh"

setup() {
    _bats_init_temp resolveVmFiles
}

teardown() {
    _bats_cleanup_temp
}

# Feed a config document on stdin, the way the wrapper pipes the vault read in.
resolve() {
    run "${BASH_BIN}" -c 'printf "%s" "$2" | "$1"' _ "${SCRIPT}" "$1"
}

# Read one value out of the emitted document.
emitted() {
    printf '%s' "${output}" | jq -r "$1"
}

@test "fails when stdin is empty" {
    resolve ''
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"no provisioner config on stdin"* ]]
}

@test "fails when the config is not valid JSON" {
    resolve 'not-json'
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"not valid JSON"* ]]
}

@test "fails when the config is not an array of VM definitions" {
    # An object here means the wrong secret was read; naming that beats
    # emitting an empty dict the playbook would silently act on.
    resolve '{"vmName":"a"}'
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"must be a JSON array"* ]]
    [[ "${output}" == *"object"* ]]
}

@test "emits a single top-level vm_files_by_host key" {
    resolve '[{"vmName":"a"}]'
    [ "${status}" -eq 0 ]
    [ "$(emitted 'keys | join(",")')" = "vm_files_by_host" ]
}

@test "a VM with no files array yields an empty list rather than a missing key" {
    # The playbook looks each host up unconditionally, so "declared nothing"
    # and "nothing to copy" must not be two different shapes.
    resolve '[{"vmName":"a"}]'
    [ "${status}" -eq 0 ]
    [ "$(emitted '.vm_files_by_host.a | length')" = "0" ]
    [ "$(emitted '.vm_files_by_host | has("a")')" = "true" ]
}

@test "translates a single-form source and leaves the VM-side target alone" {
    resolve '[{"vmName":"a","files":[{"source":"C:\\jars\\app.jar","target":"/opt/app/app.jar"}]}]'
    [ "${status}" -eq 0 ]
    [ "$(emitted '.vm_files_by_host.a[0].source')" = "/mnt/c/jars/app.jar" ]
    [ "$(emitted '.vm_files_by_host.a[0].target')" = "/opt/app/app.jar" ]
}

@test "translates a bulk-form pattern and leaves targetDir alone" {
    resolve '[{"vmName":"a","files":[{"pattern":"C:\\jars\\*.jar","targetDir":"/opt/app/lib"}]}]'
    [ "${status}" -eq 0 ]
    [ "$(emitted '.vm_files_by_host.a[0].pattern')" = "/mnt/c/jars/*.jar" ]
    [ "$(emitted '.vm_files_by_host.a[0].targetDir')" = "/opt/app/lib" ]
}

@test "carries the optional bulk sub-fields through verbatim" {
    # Schema validation belongs to the vm_files role; this script must not
    # drop, rename, or default anything on the way to it.
    resolve '[{"vmName":"a","files":[{"pattern":"C:\\src\\*","targetDir":"/opt/x","recurse":true,"preserveRelativePath":true}]}]'
    [ "${status}" -eq 0 ]
    [ "$(emitted '.vm_files_by_host.a[0].recurse')" = "true" ]
    [ "$(emitted '.vm_files_by_host.a[0].preserveRelativePath')" = "true" ]
}

@test "keys every VM by its own name and keeps their entries separate" {
    resolve '[{"vmName":"a","files":[{"source":"C:\\a.txt","target":"/opt/a.txt"}]},{"vmName":"b","files":[{"source":"D:\\b.txt","target":"/opt/b.txt"}]}]'
    [ "${status}" -eq 0 ]
    [ "$(emitted '.vm_files_by_host | keys | sort | join(",")')" = "a,b" ]
    [ "$(emitted '.vm_files_by_host.a[0].source')" = "/mnt/c/a.txt" ]
    [ "$(emitted '.vm_files_by_host.b[0].source')" = "/mnt/d/b.txt" ]
}

@test "translates every entry of a multi-entry files array" {
    resolve '[{"vmName":"a","files":[{"source":"C:\\one.txt","target":"/opt/one"},{"pattern":"C:\\many\\*.txt","targetDir":"/opt/many"}]}]'
    [ "${status}" -eq 0 ]
    [ "$(emitted '.vm_files_by_host.a | length')" = "2" ]
    [ "$(emitted '.vm_files_by_host.a[0].source')" = "/mnt/c/one.txt" ]
    [ "$(emitted '.vm_files_by_host.a[1].pattern')" = "/mnt/c/many/*.txt" ]
}

@test "the same path used by two VMs translates identically" {
    # Paths are de-duplicated before translation and reapplied by value, so
    # this is the case that would break if they were zipped back by position.
    resolve '[{"vmName":"a","files":[{"source":"C:\\shared.txt","target":"/opt/a"}]},{"vmName":"b","files":[{"source":"C:\\shared.txt","target":"/opt/b"}]}]'
    [ "${status}" -eq 0 ]
    [ "$(emitted '.vm_files_by_host.a[0].source')" = "/mnt/c/shared.txt" ]
    [ "$(emitted '.vm_files_by_host.b[0].source')" = "/mnt/c/shared.txt" ]
}

@test "an already-POSIX source passes through unchanged" {
    resolve '[{"vmName":"a","files":[{"source":"/mnt/c/jars/app.jar","target":"/opt/app.jar"}]}]'
    [ "${status}" -eq 0 ]
    [ "$(emitted '.vm_files_by_host.a[0].source')" = "/mnt/c/jars/app.jar" ]
}

@test "an untranslatable source fails the whole resolve and names the path" {
    # Failing here is the point: a UNC source would otherwise reach the role
    # as a path the controller cannot open, and surface as a bare "not found".
    resolve '[{"vmName":"a","files":[{"source":"\\\\fileserver\\share\\app.jar","target":"/opt/app.jar"}]}]'
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"UNC"* ]]
    [[ "${output}" == *"fileserver"* ]]
}

@test "an entry with neither source nor pattern rides through untouched" {
    # A malformed entry must reach the role, which owns the schema rules and
    # reports them by entry index; materialising a null sub-field here would
    # turn that report into a misleading one.
    resolve '[{"vmName":"a","files":[{"target":"/opt/app.jar"}]}]'
    [ "${status}" -eq 0 ]
    [ "$(emitted '.vm_files_by_host.a[0] | has("source")')" = "false" ]
    [ "$(emitted '.vm_files_by_host.a[0] | has("pattern")')" = "false" ]
    [ "$(emitted '.vm_files_by_host.a[0].target')" = "/opt/app.jar" ]
}

@test "a non-string source rides through untouched" {
    resolve '[{"vmName":"a","files":[{"source":42,"target":"/opt/app.jar"}]}]'
    [ "${status}" -eq 0 ]
    [ "$(emitted '.vm_files_by_host.a[0].source')" = "42" ]
}

@test "a VM without a vmName is skipped rather than keyed as null" {
    # The bridge keys hosts by vmName; an entry lacking one cannot be targeted,
    # and a "null" key would collide across every such entry.
    resolve '[{"ipAddress":"10.0.0.1"},{"vmName":"a"}]'
    [ "${status}" -eq 0 ]
    [ "$(emitted '.vm_files_by_host | keys | join(",")')" = "a" ]
}

@test "an empty fleet yields an empty dict" {
    resolve '[]'
    [ "${status}" -eq 0 ]
    [ "$(emitted '.vm_files_by_host | length')" = "0" ]
}

@test "unrelated VM fields are not carried into the emitted document" {
    # The document rides the play-wide extra-vars channel, so it must carry the
    # files desired-state and nothing else - not credentials, not the toolchain
    # taxonomy the bridge already surfaces whole.
    resolve '[{"vmName":"a","password":"s3cret","toolchains":{"baseImage":[{"name":"docker"}]},"files":[{"source":"C:\\a.txt","target":"/opt/a"}]}]'
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"s3cret"* ]]
    [[ "${output}" != *"toolchains"* ]]
}

# ---------------------------------------------------------------------------
# Windows jq (the Git Bash launch)
#
# Under the operator menu this script runs in Git Bash, where `jq` resolves to
# the WINDOWS jq.exe and every line it writes ends CRLF. That shipped as a
# silent translation failure: `mapfile -t` strips only the newline, so the
# lookup map was keyed by "<path>\r" while step 2 looked up the clean JSON
# string, and every path rode through in its Windows form to fail much later
# inside the vm_files role.
#
# bats runs on the controller, where jq writes LF, so nothing above can see it.
# The stub below makes the Windows behaviour reproducible here.
# ---------------------------------------------------------------------------

install_crlf_jq_stub() {
    local real_jq
    real_jq="$(command -v jq)"
    mkdir -p "${TEST_TMP}/stubs"
    # pipefail so a real jq failure still propagates through the sed - without
    # it the stub would mask every parse error and the guards above would pass
    # for the wrong reason.
    cat >"${TEST_TMP}/stubs/jq" <<STUB
#!/usr/bin/env bash
set -o pipefail
"${real_jq}" "\$@" | sed -e 's/\$/\r/'
STUB
    chmod +x "${TEST_TMP}/stubs/jq"
}

@test "translates a bulk pattern even when jq writes CRLF (Windows jq)" {
    install_crlf_jq_stub
    run env PATH="${TEST_TMP}/stubs:${PATH}" "${BASH_BIN}" -c 'printf "%s" "$2" | "$1"' _ "${SCRIPT}" \
        '[{"vmName":"ubuntu-02-ci","files":[{"pattern":"C:\\jars\\*.jar","targetDir":"/opt/app/lib"}]}]'
    [ "${status}" -eq 0 ]
    got="$(printf '%s' "${output}" | tr -d '\r' | jq -r '.vm_files_by_host["ubuntu-02-ci"][0].pattern')"
    [ "${got}" = "/mnt/c/jars/*.jar" ]
}

@test "translates a single-form source even when jq writes CRLF" {
    install_crlf_jq_stub
    run env PATH="${TEST_TMP}/stubs:${PATH}" "${BASH_BIN}" -c 'printf "%s" "$2" | "$1"' _ "${SCRIPT}" \
        '[{"vmName":"ubuntu-01-ci","files":[{"source":"C:\\payloads\\app.jar","target":"/opt/app/app.jar"}]}]'
    [ "${status}" -eq 0 ]
    got="$(printf '%s' "${output}" | tr -d '\r' | jq -r '.vm_files_by_host["ubuntu-01-ci"][0].source')"
    [ "${got}" = "/mnt/c/payloads/app.jar" ]
}

@test "still rejects a non-array config when jq writes CRLF" {
    # The type guard compares a jq capture against a literal, so it is exposed
    # to the same CR. MSYS bash strips it from $(...) but the controller's bash
    # does not, so the script must not depend on either.
    install_crlf_jq_stub
    run env PATH="${TEST_TMP}/stubs:${PATH}" "${BASH_BIN}" -c 'printf "%s" "$2" | "$1"' _ "${SCRIPT}" \
        '{"vmName":"ubuntu-01-ci"}'
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"must be a JSON array"* ]]
}

@test "accepts a valid array config when jq writes CRLF" {
    # Guards the inverse of the case above: a CR riding on the type capture
    # would reject a perfectly good config with "got array".
    install_crlf_jq_stub
    run env PATH="${TEST_TMP}/stubs:${PATH}" "${BASH_BIN}" -c 'printf "%s" "$2" | "$1"' _ "${SCRIPT}" \
        '[{"vmName":"ubuntu-01-ci","files":[]}]'
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"must be a JSON array"* ]]
}
