<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    ConvertFrom-VmConfigJson.ps1.
#>

# Stock Ubuntu cloud images ship a fixed set of system groups (the Debian
# base-passwd set plus a few extras like sudo / lxd / netdev). cloud-init
# creates the OS user with `useradd <name>`, which - under the default
# USERGROUPS_ENAB - also creates an eponymous private group. If a group
# named <name> ALREADY exists, useradd exits 9 ("group <name> exists") and
# aborts the WHOLE account. The result is a VM with sshd answering a banner
# but no usable login, which only surfaces much later as an opaque
# "Permission denied (password)" the first time something authenticates
# (e.g. a workload jumping through a router). 'admin' is the canonical trap:
# a legacy pre-`sudo` group Ubuntu still ships, and an obvious name an
# operator reaches for. This list is the collision set checked below.
#
# Single source of truth, script-scoped so the function and its tests share
# one definition. Matched case-insensitively (the -in default): usernames
# are conventionally lowercase, so erring toward rejecting 'Admin'/'ADMIN'
# is safer than silently shipping a VM that cannot be logged into.
$script:ReservedSystemGroupUsernames = @(
    'root', 'daemon', 'bin', 'sys', 'sync', 'games', 'man', 'lp', 'mail',
    'news', 'uucp', 'proxy', 'www-data', 'backup', 'list', 'irc', 'gnats',
    'nobody', 'nogroup', 'adm', 'tty', 'disk', 'dialout', 'fax', 'cdrom',
    'floppy', 'tape', 'sudo', 'audio', 'dip', 'operator', 'src', 'shadow',
    'utmp', 'video', 'sasl', 'plugdev', 'staff', 'users', 'netdev', 'lxd',
    'admin'
)

# ---------------------------------------------------------------------------
# Assert-VmUsernameField
#   Rejects a VM 'username' that collides with a pre-existing Ubuntu system
#   group, which would make cloud-init's useradd abort the account (see the
#   $script:ReservedSystemGroupUsernames note above for the full mechanism).
#
#   Fails fast at config-load - including setup-secrets.ps1's save path -
#   with a named cause, instead of letting the failure surface deep in
#   cloud-init as an unreachable VM. Lives in its own file so the rule stays
#   self-contained and ConvertFrom-VmConfigJson.ps1 stays a thin orchestrator.
# ---------------------------------------------------------------------------
function Assert-VmUsernameField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Vm
    )

    # 'username' is a required base field whose presence is enforced by
    # ConvertFrom-VmConfigJson before this runs; guard for absence anyway so
    # the function is safe standalone (presence errors belong to the
    # required-fields check, not here).
    if (-not $Vm.PSObject.Properties['username']) {
        return
    }

    $username = $Vm.username
    $vmName   = if ($Vm.PSObject.Properties['vmName']) { $Vm.vmName } else { '(unknown)' }

    if ($username -in $script:ReservedSystemGroupUsernames) {
        throw (
            "VM '$vmName': username '$username' collides with a pre-existing " +
            "Ubuntu system group. cloud-init's useradd would fail with " +
            "'group $username exists' (exit 9) and never create the account, " +
            "leaving the VM with sshd up but no login. Choose a username that " +
            "is not a stock system group name (e.g. 'ciadmin', 'vmadmin')."
        )
    }
}
