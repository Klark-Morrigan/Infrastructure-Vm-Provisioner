#!/usr/bin/env bash
# Shared fixtures for every Tests/Ansible/ops/*.bats file. Sourced from each
# *.bats with:
#   source "${BATS_TEST_DIRNAME}/_bats-helpers.sh"
#
# Two reasons the absolute-bash + stub-root skeleton lives here rather than
# being duplicated per file:
#   - BASH_BIN: every script under ops/ is invoked via "${BASH_BIN}" rather
#     than `bash` so the harness survives an Alpine bats image whose PATH does
#     not include /bin/bash.
#   - COMMON_AUTOMATION_ROOT: the ops/ scripts reach the shared logger through
#     imports/_log.sh, which resolves the Common-Automation SIBLING CHECKOUT.
#     CI checks out no sibling (the bash workflow is the reusable one from
#     Common-Automation, run against this repo), so each bats that executes an
#     ops/ script has to reconstruct what that script sources. One stub
#     installer means a change to the reconstruction lands in one place.
#
# Caller pattern:
#   setup()    { _bats_init_temp <prefix> }    # sets BASH_BIN, TEST_TMP,
#                                              # COMMON_AUTOMATION_ROOT
#   teardown() { _bats_cleanup_temp }

_bats_resolve_bash() {
    # shellcheck disable=SC2034 # consumed by sourcing bats files
    BASH_BIN="$(command -v bash)"
}

# Stand up a fake COMMON_AUTOMATION_ROOT carrying the cross-repo helpers the
# ops/ scripts source at runtime - currently scripts/log.sh. The stub is
# self-contained (no colors.sh dependency) and reproduces the real logger's
# no-colour output, which is exactly what the real logger emits against a
# non-TTY test stream, so log assertions hold against either.
_bats_install_common_automation_stub() {
    local root="$1"
    mkdir -p "${root}/scripts"
    cat >"${root}/scripts/log.sh" <<'STUB'
#!/usr/bin/env bash
# Test stub for Common-Automation/scripts/log.sh - the [ts] LEVEL <script>:
# stderr format, minus colour, with no cross-repo colors.sh dependency.
_log_emit() {
    local level="$1"
    shift 2
    printf '[%s] %-5s %s: %s\n' \
        "$(date +%H:%M:%S)" "${level}" \
        "${BASH_SOURCE[$(( ${#BASH_SOURCE[@]} - 1 ))]##*/}" "$*" >&2
}
log_info() { _log_emit INFO  x "$*"; }
log_warn() { _log_emit WARN  x "$*"; }
log_err()  { _log_emit ERROR x "$*"; }
STUB
}

# The second cross-repo helper an ops/ wrapper sources (via imports/_timing.sh):
# Common-Automation's scripts/timing.sh. Only wrappers pull it in, so it is a
# separate installer rather than part of the stub above. Every verb is a no-op
# and timing_enabled is false, which is what an untimed operator run sees - the
# behaviour a wrapper test wants held still while it asserts something else.
_bats_install_timing_stub() {
    local root="$1"
    mkdir -p "${root}/scripts"
    cat >"${root}/scripts/timing.sh" <<'STUB'
#!/usr/bin/env bash
timing_init()                 { :; }
timing_span_begin()           { :; }
timing_span_end()             { :; }
timing_graft_children_from()  { :; }
timing_enabled()              { return 1; }
STUB
}

_bats_init_temp() {
    _bats_resolve_bash
    TEST_TMP="$(mktemp -d -t "${1}.XXXXXX")"
    # shellcheck disable=SC2034 # consumed by sourcing bats files
    COMMON_AUTOMATION_ROOT="${TEST_TMP}/Common-Automation"
    export COMMON_AUTOMATION_ROOT
    _bats_install_common_automation_stub "${COMMON_AUTOMATION_ROOT}"
    _bats_install_timing_stub "${COMMON_AUTOMATION_ROOT}"
}

_bats_cleanup_temp() {
    rm -rf "${TEST_TMP}"
}
