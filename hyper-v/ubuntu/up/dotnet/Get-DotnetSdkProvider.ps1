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
#   Why -Vm is captured: Install-Version has to populate its manifest's
#   `children` array with the per-tool manifest paths the nested
#   dotnetTools provider will write later in the same run. The mapping
#   is `$Vm.dotnetTools` -> child entries, derived by Get-VmDotnetToolChildren
#   from the fixed manifest filename grammar (no on-VM lookup). The
#   Spec itself stays JSON-derived; $Vm only carries the cross-provider
#   derivation that the contract's typed Spec does not surface.
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
    # Predict the nested-provider children at composition time and
    # close over the resulting array. The dotnetTools provider runs
    # AFTER the SDK provider in the same dispatch pass, so the parent
    # manifest's `children` field has to be populated from the operator's
    # config rather than discovered from the on-VM filesystem (which
    # is still bare when the SDK install runs first time).
    $childEntriesFn     = ${function:Get-VmDotnetToolChildren}
    $childEntries       = @(& $childEntriesFn -Vm $Vm)

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
        # $childEntries was computed in the outer scope and is captured
        # by GetNewClosure() so the reconciler's invocation (which runs
        # in Infrastructure.HyperV's session state) still sees it.
        & $installVersionFn `
            -SshClient    $SshClient `
            -Server       $Server `
            -Spec         $Spec `
            -ChildEntries $childEntries
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
