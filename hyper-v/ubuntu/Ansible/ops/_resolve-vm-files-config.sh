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

if ! printf '%s' "${input}" | jq empty >/dev/null 2>&1; then
    log_err "provisioner config is not valid JSON"
    exit 1
fi

# The vault payload is an array of VM definitions; anything else means the
# wrong secret was read, which is worth naming here rather than letting the
# reshape below silently produce an empty dict.
config_type="$(printf '%s' "${input}" | jq -r 'type')"
if [[ "${config_type}" != "array" ]]; then
    log_err "provisioner config must be a JSON array of VM definitions (got ${config_type})"
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
# ---------------------------------------------------------------------------
# shellcheck disable=SC2312  # jq cannot fail here - the document was validated above
mapfile -t controller_paths < <(printf '%s' "${input}" | jq -r '
    .[]?
    | select(type == "object")
    | (.files? // [])[]?
    | select(type == "object")
    | (.source? // .pattern? // empty)
    | select(type == "string")
' | sort -u)

path_map='{}'
if [[ "${#controller_paths[@]}" -gt 0 ]]; then
    for windows_path in "${controller_paths[@]}"; do
        # shellcheck disable=SC2310  # predicate in `if`; the failure is handled below
        if ! posix_path="$(_to_wsl_path "${windows_path}")"; then
            log_err "cannot translate a files entry path for the WSL controller: ${windows_path}"
            exit 1
        fi
        path_map="$(jq -c --arg k "${windows_path}" --arg v "${posix_path}" \
            '. + {($k): $v}' <<<"${path_map}")"
    done
fi

# ---------------------------------------------------------------------------
# 2. Reshape and substitute. `|=` on an existing key only (guarded by has())
#    so a missing discriminator is not materialised as a null sub-field, which
#    would turn a "missing source or pattern" schema error into a confusing
#    "source is null" one.
# ---------------------------------------------------------------------------
printf '%s' "${input}" | jq --argjson map "${path_map}" '
    def translated: if type == "string" then ($map[.] // .) else . end;

    reduce (.[]? | select(type == "object") | select(.vmName? != null)) as $vm ({};
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
