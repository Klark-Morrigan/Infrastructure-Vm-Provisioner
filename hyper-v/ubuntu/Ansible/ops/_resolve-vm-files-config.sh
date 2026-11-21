#!/usr/bin/env bash
# Turns the VmProvisioner inventory config into the file-provisioning flow's
# desired-state extra-vars document, translating every controller-side path on
# the way through.
#
# Pure stdin -> stdout transform (config JSON in, extra-vars JSON out), which
# is what makes it testable without a vault, a VM, or a WSL host - the same
# split the substrate bridge uses for _build-inventory.sh.
#
# Two responsibilities, both consumer-domain:
#
# - Reshape. The `files` arrays are lifted out of the per-VM config into one
#   play-wide dict keyed by vmName (which the bridge also uses as
#   inventory_hostname), so the playbook selects a host's entries the same way
#   provision-toolchains.yml selects its resolved pins. Sub-fields ride through
#   verbatim: this script does not validate the schema, because the vm_files
#   role asserts it and a second, divergent copy of those rules here would be a
#   worse failure than no copy at all.
#
# - Translate. `source` (single form) and `pattern` (bulk form) name files on
#   the CONTROLLER, and the config authors them Windows-side. See
#   _to-wsl-path.sh for why the conversion is the consumer's job and not the
#   role's. `target` / `targetDir` are NOT translated - they are VM-side POSIX
#   paths that never saw a drive letter.
#
# Output (stdout): {"vm_files_by_host": {"<vmName>": [<entry>, ...], ...}}
# Every VM carrying a vmName appears, with an empty array when it declares no
# files, so the playbook's per-host lookup never has to distinguish "no entry"
# from "nothing to copy".

set -euo pipefail

# shellcheck source=hyper-v/ubuntu/Ansible/ops/imports/_log.sh
source "${BASH_SOURCE[0]%/*}/imports/_log.sh"

# shellcheck source=hyper-v/ubuntu/Ansible/ops/_to-wsl-path.sh
source "${BASH_SOURCE[0]%/*}/_to-wsl-path.sh"

input="$(cat)"

if [[ -z "${input}" ]]; then
    log_err "no provisioner config on stdin"
    exit 1
fi

# The vault payload is one array of VM definitions. Anything else means the
# wrong secret was read, which is worth naming here rather than letting the
# reshape below silently produce an empty dict. Slurping counts the documents:
# the reshape reads only the first, so any others would be dropped unseen.
#
# CR is stripped for the reason given in step 1. Git Bash drops a trailing CR
# from `$(...)` but the controller's bash does not, so the comparison must not
# depend on either.
if ! config_shape="$(printf '%s' "${input}" \
        | jq -rs 'if length == 1 then .[0] | type else "\(length) documents" end' 2>/dev/null \
        | tr -d '\r')"; then
    log_err "provisioner config is not valid JSON"
    exit 1
fi

if [[ "${config_shape}" != "array" ]]; then
    log_err "provisioner config must be a JSON array of VM definitions (got ${config_shape})"
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. Collect every distinct controller-side path. Translating a de-duplicated
#    set and applying it as a lookup map keeps the jq reshape below free of
#    index bookkeeping - the map is keyed by the original string, so entries
#    reassemble by value rather than by position.
#
#    Non-string source/pattern values are skipped: they are schema violations
#    the role reports far better than this script could, and they must reach it
#    unchanged to be reported at all.
#
#    `tr -d '\r'` is load-bearing. Under Git Bash - the shell the operator menu
#    launches this flow in - `jq` is the Windows jq.exe, which ends lines with
#    CRLF. `mapfile -t` strips only the newline, so a kept CR would key the
#    lookup map by "<path>\r" and every lookup in step 2 would silently miss.
#
#    Translated paths reach jq on stdin, never as arguments. Git Bash rewrites
#    any wildcard-free argument that starts with / before it launches jq.exe,
#    so /mnt/c/x.json would arrive as C:/<git-root>/mnt/c/x.json. Stdin is
#    never rewritten. Each pair is one tab-separated line, because a tab
#    cannot occur in a Windows path.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2312  # jq cannot fail here - the document was validated above
mapfile -t controller_paths < <(printf '%s' "${input}" | jq -r '
    .[]?
    | select(type == "object")
    | (.files? // [])[]?
    | select(type == "object")
    | (.source? // .pattern? // empty)
    | select(type == "string")
' | tr -d '\r' | sort -u)

path_pairs=''
for windows_path in "${controller_paths[@]}"; do
    # shellcheck disable=SC2310 # predicate in `if`; the failure is handled below
    if ! posix_path="$(_to_wsl_path "${windows_path}")"; then
        log_err "cannot translate a files entry path for the WSL controller: ${windows_path}"
        exit 1
    fi
    path_pairs+="${windows_path}"$'\t'"${posix_path}"$'\n'
done

log_info "Translated ${#controller_paths[@]} controller-side path(s)"

# ---------------------------------------------------------------------------
# 2. Reshape and substitute. The lookup map and the config travel as two
#    documents on one stream, for the stdin-only reason given in step 1.
#
#    `|=` on an existing key only (guarded by has()) so a missing discriminator
#    is not materialised as a null sub-field, which would turn a "missing
#    source or pattern" schema error into a confusing "source is null" one.
# ---------------------------------------------------------------------------
{
    printf '%s' "${path_pairs}" | jq -cRn '[inputs | split("\t") | {(.[0]): .[1]}] | add // {}'
    printf '%s' "${input}"
} | jq -n '
    input as $map
    | def translated: if type == "string" then ($map[.] // .) else . end;

    input
    | reduce (.[]? | select(type == "object") | select(.vmName? != null)) as $vm ({};
        .[$vm.vmName | tostring] = [
            ($vm.files? // [])[]?
            | if type == "object" then
                  (if has("source")  then .source  |= translated else . end)
                | (if has("pattern") then .pattern |= translated else . end)
              else . end
        ]
    )
    | {vm_files_by_host: .}
'
