#!/usr/bin/env bats
#
# Tests for
# hyper-v/ubuntu/Ansible/ops/_resolve-vm-files-config.sh,
# the stdin -> stdout reshape that lifts each VM's `files` array into the
# vm_files_by_host extra-vars document and translates every controller-side
# path on the way. Pure transform; jq is the only external dep. It runs for
# real, except in the sections at the end that stub it as the Windows jq.exe.
# Run with: bats Tests/Ansible/ops/_resolve-vm-files-config.bats

# run --separate-stderr arrived in 1.5.0.
bats_require_minimum_version 1.5.0

SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../../../hyper-v/ubuntu/Ansible/ops" && pwd)/_resolve-vm-files-config.sh"

# shellcheck source=Tests/Ansible/ops/_bats-helpers.sh
source "${BATS_TEST_DIRNAME}/_bats-helpers.sh"

setup() {

    _bats_init_temp resolveVmFiles

    REAL_JQ="$(command -v jq)"
    STUBS_DIR="${TEST_TMP}/stubs"
}

teardown() {

    _bats_cleanup_temp
}

# Feed a config document on stdin, the way the wrapper pipes the vault read in.
# The stubs folder leads PATH, so a test that installs a jq stub runs the script
# against it. Without one the folder does not exist and the real jq is found.
#
# stdout and stderr are kept apart because the wrapper writes stdout to the
# extra-vars file: a log line there would corrupt the document.
resolve() {

    run --separate-stderr env PATH="${STUBS_DIR}:${PATH}" "${BASH_BIN}" -c 'printf "%s" "$2" | "$1"' _ "${SCRIPT}" "$1"
}

# Read one value out of the emitted document. CR is stripped first, so output
# written through a CRLF stub reads the same as any other.
emitted() {

    printf '%s' "${output}" | tr -d '\r' | jq -r "$1"
}

@test "fails when stdin is empty" {

    resolve ''

    [ "${status}" -ne 0 ]
    [[ "${stderr}" == *"no provisioner config on stdin"* ]]
}

@test "fails when the config is not valid JSON" {

    resolve 'not-json'

    [ "${status}" -ne 0 ]
    [[ "${stderr}" == *"not valid JSON"* ]]
}

@test "fails when the config is not an array of VM definitions" {

    # An object here means the wrong secret was read; naming that beats
    # emitting an empty dict the playbook would silently act on.
    resolve '{"vmName":"a"}'

    [ "${status}" -ne 0 ]
    [[ "${stderr}" == *"must be a JSON array"* ]]
    [[ "${stderr}" == *"object"* ]]
}

@test "fails when stdin carries more than one document and says how many" {

    # Only the first document would be reshaped, so a second one would be
    # dropped without a word.
    resolve '[{"vmName":"a"}] [{"vmName":"b"}]'

    [ "${status}" -ne 0 ]
    [[ "${stderr}" == *"must be a JSON array"* ]]
    [[ "${stderr}" == *"2 documents"* ]]
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
    [[ "${stderr}" == *"UNC"* ]]
    [[ "${stderr}" == *"fileserver"* ]]
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

@test "reports how many distinct paths it translated on stderr, keeping stdout a clean document" {

    resolve '[{"vmName":"a","files":[{"source":"C:\\a.txt","target":"/opt/a"},{"pattern":"C:\\b\\*.jar","targetDir":"/opt/b"}]},{"vmName":"b","files":[{"source":"C:\\a.txt","target":"/opt/a"}]}]'

    [ "${status}" -eq 0 ]
    [[ "${stderr}" == *"Translated 2 controller-side path(s)"* ]]
    [ "$(emitted 'keys | join(",")')" = "vm_files_by_host" ]
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
# Windows jq stubs (the Git Bash launch)
#
# Under the operator menu this script runs in Git Bash, where `jq` resolves to
# the WINDOWS jq.exe. bats runs on the controller, where jq is a Linux binary,
# so the sections above cannot see how jq.exe behaves. These stubs reproduce
# it. Each one wraps a next jq - the real one, or another stub - so the
# Windows stub is the two behaviours chained rather than a third copy of them.
# ---------------------------------------------------------------------------

# write_jq_stub <name> <next-jq>
#
# Writes the stub body read from stdin to the stubs folder. The body calls the
# jq it wraps as "${next_jq}".
write_jq_stub() {

    local name="$1"
    local next_jq="$2"

    mkdir -p "${STUBS_DIR}"

    {
        printf '#!/usr/bin/env bash\nnext_jq=%q\n' "${next_jq}"
        cat
    } >"${STUBS_DIR}/${name}"

    chmod +x "${STUBS_DIR}/${name}"
}

# jq.exe ends every line it writes with CRLF. pipefail so a jq failure still
# propagates through the sed - without it the stub would mask every parse
# error and the guards above would pass for the wrong reason.
write_crlf_jq_stub() {

    write_jq_stub "$1" "$2" <<'STUB'
set -o pipefail
"${next_jq}" "$@" | sed -e 's/$/\r/'
STUB
}

# Before Git Bash starts a Windows program, it rewrites every argument that
# looks like a POSIX path into a Windows one under its install root:
# /mnt/c/x.json becomes C:/<git-root>/mnt/c/x.json. Arguments holding a glob
# character are left alone, so only wildcard-free paths are affected.
write_arg_rewriting_jq_stub() {

    write_jq_stub "$1" "$2" <<'STUB'
readonly msys_root='C:/msys-root'
args=()
for arg in "$@"; do
    if [[ "${arg}" == /* && "${arg}" != *[*?]* ]]; then
        arg="${msys_root}${arg}"
    fi
    args+=("${arg}")
done
exec "${next_jq}" "${args[@]}"
STUB
}

install_crlf_jq_stub() {

    write_crlf_jq_stub jq "${REAL_JQ}"
}

install_arg_rewriting_jq_stub() {

    write_arg_rewriting_jq_stub jq "${REAL_JQ}"
}

# Git Bash rewrites the arguments before jq.exe starts, and jq.exe then writes
# CRLF, so the rewriting stub is the one on PATH and it calls the CRLF one.
install_windows_jq_stub() {

    write_crlf_jq_stub jq-crlf "${REAL_JQ}"
    write_arg_rewriting_jq_stub jq "${STUBS_DIR}/jq-crlf"
}

# ---------------------------------------------------------------------------
# jq writes CRLF
#
# `mapfile -t` strips only the newline, so a CR left on each collected path
# would key the lookup map by "<path>\r". Step 2 looks paths up by the clean
# JSON string, so every path would ride through in its Windows form and fail
# much later inside the vm_files role.
# ---------------------------------------------------------------------------

@test "translates a bulk pattern even when jq writes CRLF" {

    install_crlf_jq_stub

    resolve '[{"vmName":"ubuntu-02-ci","files":[{"pattern":"C:\\jars\\*.jar","targetDir":"/opt/app/lib"}]}]'

    [ "${status}" -eq 0 ]
    [ "$(emitted '.vm_files_by_host["ubuntu-02-ci"][0].pattern')" = "/mnt/c/jars/*.jar" ]
}

@test "translates a single-form source even when jq writes CRLF" {

    install_crlf_jq_stub

    resolve '[{"vmName":"ubuntu-01-ci","files":[{"source":"C:\\payloads\\app.jar","target":"/opt/app/app.jar"}]}]'

    [ "${status}" -eq 0 ]
    [ "$(emitted '.vm_files_by_host["ubuntu-01-ci"][0].source')" = "/mnt/c/payloads/app.jar" ]
}

@test "still rejects a non-array config when jq writes CRLF" {

    # The type guard compares a jq capture against a literal, so it is exposed
    # to the same CR. MSYS bash strips it from $(...) but the controller's bash
    # does not, so the script must not depend on either.
    install_crlf_jq_stub

    resolve '{"vmName":"ubuntu-01-ci"}'

    [ "${status}" -ne 0 ]
    [[ "${stderr}" == *"must be a JSON array"* ]]
}

@test "accepts a valid array config when jq writes CRLF" {

    # Guards the inverse of the case above: a CR riding on the type capture
    # would reject a perfectly good config with "got array".
    install_crlf_jq_stub

    resolve '[{"vmName":"ubuntu-01-ci","files":[]}]'

    [ "${status}" -eq 0 ]
    [[ "${stderr}" != *"must be a JSON array"* ]]
}

# ---------------------------------------------------------------------------
# Git Bash rewrites jq arguments
#
# A translated path handed to jq on its command line arrives mangled, and the
# vm_files role rejects it as not absolute.
# ---------------------------------------------------------------------------

@test "translates a wildcard-free bulk pattern when Git Bash rewrites jq arguments" {

    install_arg_rewriting_jq_stub

    resolve '[{"vmName":"a","files":[{"pattern":"C:\\mods\\lunalib\\mod_info.json","targetDir":"/opt/mods"}]}]'

    [ "${status}" -eq 0 ]
    [ "$(emitted '.vm_files_by_host.a[0].pattern')" = "/mnt/c/mods/lunalib/mod_info.json" ]
}

@test "translates a single-form source when Git Bash rewrites jq arguments" {

    install_arg_rewriting_jq_stub

    resolve '[{"vmName":"a","files":[{"source":"C:\\payloads\\app.jar","target":"/opt/app/app.jar"}]}]'

    [ "${status}" -eq 0 ]
    [ "$(emitted '.vm_files_by_host.a[0].source')" = "/mnt/c/payloads/app.jar" ]
}

@test "translates wildcard and wildcard-free paths alike when Git Bash rewrites jq arguments" {

    install_arg_rewriting_jq_stub

    resolve '[{"vmName":"a","files":[{"pattern":"C:\\jars\\*.jar","targetDir":"/opt/lib"},{"pattern":"C:\\mods\\mod_info.json","targetDir":"/opt/mods"}]}]'

    [ "${status}" -eq 0 ]
    [ "$(emitted '.vm_files_by_host.a[0].pattern')" = "/mnt/c/jars/*.jar" ]
    [ "$(emitted '.vm_files_by_host.a[1].pattern')" = "/mnt/c/mods/mod_info.json" ]
}

# ---------------------------------------------------------------------------
# Windows jq: both behaviours at once, as the real jq.exe under Git Bash
# ---------------------------------------------------------------------------

@test "translates a fleet's mixed entries under Windows jq" {

    install_windows_jq_stub

    resolve '[
        {"vmName":"ubuntu-01-router"},
        {"vmName":"ubuntu-02-ci","files":[
            {"pattern":"C:\\mods\\lunalib\\jars\\*.jar","targetDir":"/opt/mods/lunalib/jars","recurse":true},
            {"pattern":"C:\\mods\\lunalib\\mod_info.json","targetDir":"/opt/mods/lunalib"},
            {"pattern":"C:\\mods\\Console Commands\\mod_info.json","targetDir":"/opt/mods/ConsoleCommands"},
            {"source":"D:\\payloads\\app.jar","target":"/opt/app/app.jar"}
        ]}
    ]'

    [ "${status}" -eq 0 ]
    [ "$(emitted '.vm_files_by_host["ubuntu-01-router"] | length')" = "0" ]
    [ "$(emitted '.vm_files_by_host["ubuntu-02-ci"][0].pattern')" = "/mnt/c/mods/lunalib/jars/*.jar" ]
    [ "$(emitted '.vm_files_by_host["ubuntu-02-ci"][1].pattern')" = "/mnt/c/mods/lunalib/mod_info.json" ]
    [ "$(emitted '.vm_files_by_host["ubuntu-02-ci"][2].pattern')" = "/mnt/c/mods/Console Commands/mod_info.json" ]
    [ "$(emitted '.vm_files_by_host["ubuntu-02-ci"][3].source')" = "/mnt/d/payloads/app.jar" ]
}
