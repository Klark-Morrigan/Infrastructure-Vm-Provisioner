#!/usr/bin/env bats
# Tests for hyper-v/ubuntu/Ansible/ops/_to-wsl-path.sh - the Windows -> WSL
# path helper the file and toolchain flows both translate controller-side
# paths with. Pure string transform, no external dependency, so every case
# runs identically on a WSL dev box and a bare Linux CI runner.
# Run with: bats Tests/Ansible/ops/_to-wsl-path.bats

SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../../../hyper-v/ubuntu/Ansible/ops" && pwd)/_to-wsl-path.sh"

# shellcheck source=Tests/Ansible/ops/_bats-helpers.sh
source "${BATS_TEST_DIRNAME}/_bats-helpers.sh"

# The helper sources nothing, so this file needs BASH_BIN but neither a scratch
# dir nor the Common-Automation stub.
setup() {
    _bats_resolve_bash
}

# Run the helper in a child shell so a rejection's non-zero return is captured
# rather than aborting the test file.
translate() {
    run "${BASH_BIN}" -c '
        source "$1"
        _to_wsl_path "$2"
    ' _ "${SCRIPT}" "$1"
}

@test "sourcing defines _to_wsl_path" {
    source "${SCRIPT}"
    declare -F _to_wsl_path >/dev/null
}

@test "translates an upper-case drive letter to its lower-case mount" {
    translate 'C:\jars\app.jar'
    [ "${status}" -eq 0 ]
    [ "${output}" = "/mnt/c/jars/app.jar" ]
}

@test "translates a lower-case drive letter" {
    # Config is hand-authored, so the drive arrives in whatever case the
    # operator typed; the automount is lower-case either way.
    translate 'c:\jars\app.jar'
    [ "${status}" -eq 0 ]
    [ "${output}" = "/mnt/c/jars/app.jar" ]
}

@test "translates a non-C drive" {
    translate 'D:\payloads\config.json'
    [ "${status}" -eq 0 ]
    [ "${output}" = "/mnt/d/payloads/config.json" ]
}

@test "accepts forward slashes as the separator" {
    translate 'C:/jars/app.jar'
    [ "${status}" -eq 0 ]
    [ "${output}" = "/mnt/c/jars/app.jar" ]
}

@test "accepts a mix of forward and back slashes" {
    translate 'C:/jars\nested/app.jar'
    [ "${status}" -eq 0 ]
    [ "${output}" = "/mnt/c/jars/nested/app.jar" ]
}

@test "translates a bare drive root" {
    translate 'C:\'
    [ "${status}" -eq 0 ]
    [ "${output}" = "/mnt/c/" ]
}

@test "leaves a glob pattern's wildcards untouched" {
    # Bulk `files` entries carry a pattern, not a literal path; translation
    # must not disturb the wildcards the role resolves against.
    translate 'C:\jars\*.jar'
    [ "${status}" -eq 0 ]
    [ "${output}" = "/mnt/c/jars/*.jar" ]
}

@test "passes an already-POSIX absolute path through unchanged" {
    translate '/mnt/c/jars/app.jar'
    [ "${status}" -eq 0 ]
    [ "${output}" = "/mnt/c/jars/app.jar" ]
}

@test "passes a relative path through unchanged" {
    translate 'payloads/app.jar'
    [ "${status}" -eq 0 ]
    [ "${output}" = "payloads/app.jar" ]
}

@test "preserves spaces in the path" {
    translate 'C:\Program Files\tool\app.jar'
    [ "${status}" -eq 0 ]
    [ "${output}" = "/mnt/c/Program Files/tool/app.jar" ]
}

@test "rejects a backslash UNC path" {
    translate '\\fileserver\share\app.jar'
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"UNC"* ]]
}

@test "rejects a forward-slash UNC path" {
    # //server/share is the same share in the form a copied-from-a-URL config
    # is likely to carry, and just as unreachable through the automount.
    translate '//fileserver/share/app.jar'
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"UNC"* ]]
}

@test "rejects a drive-relative path" {
    translate 'C:app.jar'
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"drive-relative"* ]]
}

@test "names the offending path in the rejection message" {
    translate '\\fileserver\share\app.jar'
    [ "${status}" -ne 0 ]
    [[ "${output}" == *'\\fileserver\share\app.jar'* ]]
}
