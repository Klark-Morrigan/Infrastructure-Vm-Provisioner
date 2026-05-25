<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1 after
    every JdkProvider.* operation file is loaded.
#>

# ---------------------------------------------------------------------------
# Get-JdkProvider
#   Composes the four JdkProvider.* operations into a single
#   IToolchainProvider object (see
#   hyper-v/ubuntu/up/reconciler/Provider-Contract.ps1) that Get-Providers
#   hands to the reconciler.
#
#   The reconciler's Install-Version signature is ($SshClient, $Server,
#   $Spec) by contract - no slot for the host-side acquisition outputs
#   (_jdkTarballPath / _jdkResolvedVersion) that Invoke-JdkAcquisition
#   stamps onto the VM object earlier in the provisioning pipeline. To
#   bridge that gap, Get-JdkProvider takes the Vm as a parameter and
#   captures it via GetNewClosure() so the Install-Version scriptblock
#   can forward the cached tarball path and resolved version to
#   Install-JdkVersion. This keeps the Spec shape pure JSON-derived state
#   (per Install-JdkVersion's header) and avoids leaking host-side
#   transient state through the reconciler's typed contract.
#
#   Why a function (rather than a script-scoped constant): the
#   scriptblocks reference helpers (Get-JdkDesiredVersions, ...,
#   Install-JdkVersion) that are loaded by dot-source. Deferring
#   construction to call time keeps registration order independent of
#   file-load order in provision.ps1.
# ---------------------------------------------------------------------------

function Get-JdkProvider {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Vm
    )

    # GetNewClosure() snapshots $Vm into each scriptblock so the closure
    # still sees it after Get-JdkProvider returns and its locals fall
    # out of scope. The orchestrator's call site invokes these
    # scriptblocks from another module's session state, where bare
    # variable lookup would not find $Vm.
    $getDesired = {
        param($VmConfig)
        Get-JdkDesiredVersions -VmConfig $VmConfig
    }.GetNewClosure()

    $getInstalled = {
        param($SshClient)
        Get-JdkInstalledVersions -SshClient $SshClient
    }.GetNewClosure()

    $installVersion = {
        param($SshClient, $Server, $Spec)
        Install-JdkVersion `
            -SshClient       $SshClient `
            -Server          $Server `
            -Spec            $Spec `
            -TarballPath     $Vm._jdkTarballPath `
            -ResolvedVersion $Vm._jdkResolvedVersion
    }.GetNewClosure()

    $uninstallVersion = {
        param($SshClient, $Installed)
        Uninstall-JdkVersion -SshClient $SshClient -Installed $Installed
    }.GetNewClosure()

    [PSCustomObject]@{
        Name                    = 'javaDevKit'
        'Get-DesiredVersions'   = $getDesired
        'Get-InstalledVersions' = $getInstalled
        'Install-Version'       = $installVersion
        'Uninstall-Version'     = $uninstallVersion
    }
}
