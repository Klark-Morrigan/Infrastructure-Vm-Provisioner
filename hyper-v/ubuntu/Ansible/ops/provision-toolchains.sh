#!/usr/bin/env bash
# Operator wrapper for the Ansible toolchain provisioning flow. The flow's
# heavy lifting (tmpdir, venv activation, vault reads, inventory, router
# resolution, host file server, extra-vars, dispatch) lives in the
# Common-Ansible substrate bridge, consumed as a sibling checkout (see README
# "Consuming Common-Ansible"). This wrapper owns the two concerns the
# consumer-agnostic bridge intentionally does not:
#
# - Acquisition + integrity (_stage-toolchain-artifacts.sh). The roles pull
#   their tarballs / packages from the file server by archive name and do not
#   verify a checksum at install, so this repo - the deploying consumer that
#   owns the estate's egress - resolves each desired toolchain, fetches it from
#   upstream, verifies its checksum, and stages it under the archive name the
#   role pulls by, before the bridge spins the file server over that directory.
# - The pin, per host. Staging resolves each VM's loose pins to CONCRETE builds
#   and forwards them as a single play-wide --extra-vars dict keyed by vmName
#   (toolchains_resolved_by_host); the playbook selects each host's entry by
#   inventory_hostname, so a host's install-time re-resolve lands on exactly the
#   build that was verified and staged for it, and each host installs only its
#   own toolchains.
#
# Everything else it declares through the CA_* consumer contract: the
# VmProvisioner inventory vault (which now also holds the desired toolchains -
# the staging step reads and aggregates them from there, so there is no
# separate desired-state vault), and the host file server the tarball/package
# pulls need (CA_NEEDS_HOST_FILE_SERVER=1 plus the staged dir/version). The
# bridge threads the file server URL to the roles through its always-on
# inventory fragment, so no extra vault is declared. This repo owns the
# toolchain playbook, so it declares CA_CONSUMER_ROOT as its own Ansible-slice
# root; the bridge resolves the playbook from here. The reusable roles (jdk /
# dotnet_sdk / dotnet_tools) stay substrate, resolved from the sibling checkout.
#
# Forwarded args follow the playbook path so operators can pass --tags,
# --limit, --check, -v, etc. unchanged.

set -euo pipefail

# SECRET_SUFFIX selects the lifecycle whose secrets this run reads (e.g.
# Production). Required both by the staging step (which vault to read) and by
# the bridge; validate it here so the failure is one clear message rather than
# an opaque empty-suffix error deeper in.
if [[ -z "${SECRET_SUFFIX:-}" ]]; then
    echo "SECRET_SUFFIX must be set (e.g. Production or the caller's lifecycle label)" >&2
    exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This repo's Ansible-slice root (ops/ -> Ansible/): the consumer root the
# bridge resolves the playbook and the Toolchains fragment from.
CA_CONSUMER_ROOT="$(cd "${script_dir}/.." && pwd)"

# shellcheck source=hyper-v/ubuntu/Ansible/ops/imports/_log.sh
source "${script_dir}/imports/_log.sh"
# shellcheck source=hyper-v/ubuntu/Ansible/ops/imports/_common-ansible-root.sh
source "${script_dir}/imports/_common-ansible-root.sh"

# Pre-stage the toolchain artifacts Windows-side and learn the directory the
# file server will serve, its version tag, and the concrete pinned-versions
# document to hand the roles. This runs before the bridge so the bridge only
# needs to serve the directory it is handed. The helper narrates on stderr and
# prints three KEY=value lines on stdout.
log_info "Staging toolchain artifacts (resolve, verify checksum, stage) ..."
stage_out="$("${script_dir}/_stage-toolchain-artifacts.sh" --suffix "${SECRET_SUFFIX}")"
staging_dir="$(grep     '^STAGING_DIR='         <<<"${stage_out}" | head -n1 | cut -d= -f2-)"
staging_version="$(grep '^STAGING_VERSION='     <<<"${stage_out}" | head -n1 | cut -d= -f2-)"
resolved_wsl="$(grep    '^RESOLVED_CONFIG_WSL=' <<<"${stage_out}" | head -n1 | cut -d= -f2-)"
if [[ -z "${staging_dir}" || -z "${staging_version}" || -z "${resolved_wsl}" ]]; then
    log_err "staging helper did not return STAGING_DIR/STAGING_VERSION/RESOLVED_CONFIG_WSL"
    exit 1
fi

export CA_INVENTORY_VAULT=VmProvisioner
# The roles fetch their artifacts from a Windows-side HttpListener the bridge
# spins up over the staged directory; its URL reaches the roles via the bridge's
# always-on inventory fragment (no extra vault needed).
export CA_NEEDS_HOST_FILE_SERVER=1
export CA_HOST_FILE_SERVER_DIR="${staging_dir}"
export CA_HOST_FILE_SERVER_VERSION="${staging_version}"
export CA_CONSUMER_ROOT

# The per-host concrete pins ride as a single play-wide --extra-vars dict
# (toolchains_resolved_by_host); the playbook selects each host's entry so the
# roles install exactly what staging verified for that host. The path is
# /mnt-form because ansible-playbook reads it under the WSL controller.
exec "${common_ansible_root}/ops/_run-playbook.sh" \
    playbooks/provision-toolchains.yml \
    --extra-vars "@${resolved_wsl}" \
    "$@"
