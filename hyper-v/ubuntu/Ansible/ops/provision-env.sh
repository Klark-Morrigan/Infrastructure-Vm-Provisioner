#!/usr/bin/env bash
# Operator wrapper for the Ansible environment variable provisioning flow - the
# operator-declared `envVars` object of each VM definition, reconciled into
# /etc/environment on the provisioned VMs. The flow's heavy lifting (tmpdir,
# venv activation, vault reads, inventory, router resolution, extra-vars,
# dispatch) lives in the Common-Ansible substrate bridge, consumed as a sibling
# checkout (see README "Consuming Common-Ansible").
#
# Unlike its provision-files.sh peer this wrapper owns NO concern of its own -
# it is contract plus dispatch. That is not an oversight: the files wrapper
# exists in the shape it does because `files` entries name their sources on the
# Windows host that authored the config, so someone has to reshape the config
# and rewrite every path to its /mnt form before ansible-playbook (which runs
# under the WSL controller) can open them. `envVars` values are VM-side POSIX
# strings that never saw a drive letter, so the desired state is already inside
# the whole-config document the bridge surfaces on every dispatch
# (vm_provisioner_config) and the playbook selects straight off it. No vault
# read, no reshape, no temp document, and none of the two-spelling handoff that
# the extra-vars path needs.
#
# Everything it does declare is the CA_* consumer contract: the VmProvisioner
# inventory vault (which also holds the `envVars` desired-state, so there is no
# separate vault to declare), and this repo's Ansible-slice root, from which
# the bridge resolves the playbook. The vm_env_vars / env_vars_report roles
# stay substrate, resolved from the sibling checkout.
#
# Notably absent: CA_NEEDS_HOST_FILE_SERVER. The toolchain flow needs a
# Windows-side HttpListener because its roles pull tarballs by URL; nothing
# here transfers a payload at all - the variables ride in the extra-vars the
# bridge already builds.
#
# Forwarded args follow the playbook path so operators can pass --tags, --limit,
# --check, -v, etc. unchanged.

set -euo pipefail

# SECRET_SUFFIX validation, CA_CONSUMER_ROOT, the four sourced helpers, the
# timing emitter and the shared CA_* contract - see _flow-preamble.sh.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
flow_name="provision-env"
# shellcheck source=hyper-v/ubuntu/Ansible/ops/_flow-preamble.sh
source "${script_dir}/_flow-preamble.sh"

# Nothing stands between the preamble and the dispatch, which is the whole
# shape of this flow. Last statement, so the playbook's exit code is this
# script's: nothing is held open across the dispatch (the files wrapper
# captures the code only because it has a temp document to remove either way),
# and the timing emitter flushes from its own EXIT trap regardless.
dispatch_playbook playbooks/provision-env.yml "$@"
