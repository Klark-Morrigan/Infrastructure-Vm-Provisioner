#!/usr/bin/env bash
# Cross-repo adapter: imports _to_windows_path from Common-Automation
# (scripts/_to-windows-path.sh) - converts a WSL/Linux path to the Windows
# form arguments handed to pwsh.exe / cmd.exe require. Only the scripts that
# shell out to a Windows process (_stage-toolchain-artifacts) source this.
# See _common-automation-root.sh for repo-root resolution.
# shellcheck source=hyper-v/ubuntu/Ansible/ops/imports/_common-automation-root.sh
source "${BASH_SOURCE[0]%/*}/_common-automation-root.sh"
# shellcheck source=/dev/null
source "${common_automation_root}/scripts/_to-windows-path.sh"
