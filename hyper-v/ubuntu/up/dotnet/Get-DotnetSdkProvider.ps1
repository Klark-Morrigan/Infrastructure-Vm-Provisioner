<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1 after every
    DotnetSdkProvider.* operation file is loaded.
#>

# ---------------------------------------------------------------------------
# Get-DotnetSdkProvider
#   Composes the four DotnetSdkProvider.* operations into a single
#   IToolchainProvider object (see
#   hyper-v/ubuntu/up/reconciler/Provider-Contract.ps1) that Get-Providers
#   hands to the reconciler.
#
#   Mirrors Get-JdkProvider in shape: each contract scriptblock forwards
#   to the underlying helper function. Helpers are captured as scriptblock-
#   local variables BEFORE the closures are constructed because the
#   orchestrator invokes the scriptblocks from inside Invoke-WithVmFileServer
#   (Infrastructure.HyperV's session state), where bare name lookup of
#   provision.ps1's dot-sourced helpers fails. GetNewClosure() preserves
#   these function variables across the scope hop; the closure body invokes
#   them via the call operator so resolution does not need the originating
#   scope. Same pattern as Get-JdkProvider.ps1.
#
#   Why -Vm is accepted but not closed over: Get-Providers passes the
#   per-VM object to every provider factory for symmetry, and a future
#   per-Vm decision (e.g. a feature-gated channel override) can be wired
#   here without changing the call site. Today's DotnetSdkProvider needs
#   nothing from the Vm at composition time - the Spec produced by
#   Get-DotnetSdkDesiredVersions already carries TarballPath and the
#   resolved Version (stamped by Invoke-DotnetSdkAcquisition), so
#   Install-Version forwards the Spec straight through without needing
#   the host-side $Vm in scope.
# ---------------------------------------------------------------------------

function Get-DotnetSdkProvider {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Vm
    )

    $getDesiredFn       = ${function:Get-DotnetSdkDesiredVersions}
    $getInstalledFn     = ${function:Get-DotnetSdkInstalledVersions}
    $installVersionFn   = ${function:Install-DotnetSdkVersion}
    $uninstallVersionFn = ${function:Uninstall-DotnetSdkVersion}

    $getDesired = {
        param($VmConfig)
        & $getDesiredFn -VmConfig $VmConfig
    }.GetNewClosure()

    $getInstalled = {
        param($SshClient)
        & $getInstalledFn -SshClient $SshClient
    }.GetNewClosure()

    $installVersion = {
        param($SshClient, $Server, $Spec)
        & $installVersionFn `
            -SshClient $SshClient `
            -Server    $Server `
            -Spec      $Spec
    }.GetNewClosure()

    $uninstallVersion = {
        param($SshClient, $Installed)
        & $uninstallVersionFn -SshClient $SshClient -Installed $Installed
    }.GetNewClosure()

    [PSCustomObject]@{
        Name                    = 'dotnetSdk'
        'Get-DesiredVersions'   = $getDesired
        'Get-InstalledVersions' = $getInstalled
        'Install-Version'       = $installVersion
        'Uninstall-Version'     = $uninstallVersion
    }
}
