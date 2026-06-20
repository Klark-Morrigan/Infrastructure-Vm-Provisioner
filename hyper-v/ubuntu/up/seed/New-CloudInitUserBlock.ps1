<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1 alongside the other up/seed/* helpers.
#>

# ---------------------------------------------------------------------------
# New-CloudInitUserBlock
#   Returns the cloud-config YAML fragment that creates the OS user and
#   enables SSH password auth. Shared by the workload and router seed
#   generators so the user shape (groups, sudo policy, lock_passwd) is
#   owned in one place.
#
#   plain_text_passwd lets cloud-init hash the password internally,
#   avoiding the need to pre-compute a sha512crypt hash on Windows.
#   lock_passwd must be false - without it cloud-init locks the account
#   after setting the password, blocking SSH password auth even when
#   ssh_pwauth is true.
#
#   Specifying users: without 'default' in the list intentionally omits
#   the cloud image's built-in 'ubuntu' user; only the configured user
#   is created.
#
#   SECURITY: the returned string contains the password in plaintext so
#   cloud-init can hash it. The caller is responsible for keeping the
#   seed ISO short-lived (the workload pipeline removes it as soon as
#   SSH is reachable).
#
#   YAML escapes: backslash and double-quote are the two characters that
#   break a YAML double-quoted scalar. They are escaped here so a
#   domain\user credential or a password containing `"` does not corrupt
#   the cloud-config document.
# ---------------------------------------------------------------------------
function New-CloudInitUserBlock {
    [CmdletBinding()]
    [OutputType([string])]
    # cloud-init's plain_text_passwd field requires the literal password
    # text, and the provisioner pipeline already carries it as a plain
    # string (Get-Secret -AsPlainText). A [SecureString]/[PSCredential]
    # here would be converted straight back to plain text to emit the
    # YAML, adding ceremony with no security gain, so both credential
    # rules are suppressed for this leaf function.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingUsernameAndPasswordParams', '')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', 'Password')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Username,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Password
    )

    $yamlUsername = $Username -replace '\\', '\\' -replace '"', '\"'
    $yamlPassword = $Password -replace '\\', '\\' -replace '"', '\"'

    return @"
users:
  - name: "$yamlUsername"
    plain_text_passwd: "$yamlPassword"
    lock_passwd: false
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: [adm, cdrom, dip, plugdev, lxd]

ssh_pwauth: true
"@
}
