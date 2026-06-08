<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1 ahead of
    New-VmSshTunnel / New-VmSshClientWithJump so those helpers can
    fail fast (with a clear message) if the SSH.NET assembly is not
    in process.
#>

# ---------------------------------------------------------------------------
# Assert-SshNetLoaded
#   Confirms the Renci.SshNet types that New-VmSshTunnel and
#   New-VmSshClientWithJump construct directly are reachable. Posh-SSH
#   imports them as a side-effect of Import-Module (see
#   Install-ModuleDependencies.ps1 - Posh-SSH is pulled in solely for
#   the bundled Renci.SshNet.dll). If a caller invokes a jump-aware
#   helper before that import has happened, the native error is an
#   opaque "Unable to find type" deep inside the helper. This guard
#   surfaces the cause up front instead.
#
#   ForwardedPortLocal is checked alongside SshClient because the
#   jump-host path depends on local port forwarding; SshClient alone
#   would let a broken / partial assembly load slip through.
# ---------------------------------------------------------------------------
function Assert-SshNetLoaded {
    [CmdletBinding()]
    param()

    $required = @(
        'Renci.SshNet.SshClient',
        'Renci.SshNet.ForwardedPortLocal',
        'Renci.SshNet.PasswordAuthenticationMethod',
        'Renci.SshNet.ConnectionInfo'
    )

    foreach ($typeName in $required) {
        if (-not ($typeName -as [type])) {
            throw (
                "SSH.NET type '$typeName' is not loaded. Posh-SSH must " +
                "be imported before the jump-aware SSH helpers run - " +
                "Install-ModuleDependencies.ps1 installs it; provision.ps1 " +
                "imports it via Import-Module Posh-SSH. If you are " +
                "running these helpers outside provision.ps1, run " +
                "Import-Module Posh-SSH first."
            )
        }
    }
}
