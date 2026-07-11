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

    # Capture helper functions as scriptblock-local variables BEFORE
    # creating each closure. The orchestrator invokes these scriptblocks
    # from inside Invoke-WithVmFileServer (Infrastructure.HyperV's
    # session state), where bare name lookup of provision.ps1's
    # dot-sourced helpers fails. GetNewClosure() preserves $Vm AND
    # these function variables; the closure body invokes them via the
    # call operator so resolution does not need the originating scope.
    # Same pattern as Invoke-VmPostProvisioning.ps1's $copyVmFiles etc.
    $getDesiredFn       = ${function:Get-JdkDesiredVersions}
    $getInstalledFn     = ${function:Get-JdkInstalledVersions}
    $installVersionFn   = ${function:Install-JdkVersion}
    $uninstallVersionFn = ${function:Uninstall-JdkVersion}

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
        # ResolvedVersion now comes from the Spec itself
        # (Get-JdkDesiredVersions populates Spec.Version from
        # $Vm._jdkResolvedVersion). The TarballPath still has to come
        # from the closure-captured $Vm because it is a host-side
        # path the reconciler contract does not surface on the Spec.
        & $installVersionFn `
            -SshClient       $SshClient `
            -Server          $Server `
            -Spec            $Spec `
            -TarballPath     $Vm._jdkTarballPath `
            -ResolvedVersion $Spec.Version
    }.GetNewClosure()

    $uninstallVersion = {
        param($SshClient, $Installed)
        & $uninstallVersionFn -SshClient $SshClient -Installed $Installed
    }.GetNewClosure()

    [PSCustomObject]@{
        Name                    = 'javaDevKit'
        'Get-DesiredVersions'   = $getDesired
        'Get-InstalledVersions' = $getInstalled
        'Install-Version'       = $installVersion
        'Uninstall-Version'     = $uninstallVersion
    }
}
