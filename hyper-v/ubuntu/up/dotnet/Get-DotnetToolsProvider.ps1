<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1 after every
    DotnetToolsProvider.* operation file is loaded.
#>

# ---------------------------------------------------------------------------
# Get-DotnetToolsProvider
#   Composes the four DotnetToolsProvider.* operations into a single
#   IToolchainProvider object (see
#   hyper-v/ubuntu/up/reconciler/Provider-Contract.ps1) that Get-Providers
#   hands to the reconciler.
#
#   Unlike Get-DotnetSdkProvider, this provider carries a non-empty
#   ParentProvider member. The orchestrator does NOT dispatch nested
#   providers in its top-level loop; they run only via the children walker
#   when the parent provider's manifest names them in its `children`
#   array. The parent (dotnetSdk) is responsible for populating that
#   array at install time - see Get-VmDotnetToolChildren in
#   DotnetSdkProvider.Install-Version.ps1, which is the only place the
#   parent provider depends on this child.
#
#   Closure construction mirrors Get-DotnetSdkProvider: helpers are
#   captured into scriptblock-local variables BEFORE the closures are
#   built because the reconciler invokes the scriptblocks from inside
#   Invoke-WithVmFileServer (Infrastructure.HyperV's session state),
#   where bare name lookup of provision.ps1's dot-sourced helpers
#   fails. GetNewClosure() preserves these function variables; the
#   closure body invokes them via the call operator so resolution does
#   not need the originating scope.
#
#   Why -Vm is accepted but not closed over: kept for parity with the
#   sibling provider factories so Get-Providers can pass $Vm to every
#   factory uniformly. The Spec produced by Get-DotnetToolsDesiredVersions
#   already carries Id, RawVersion, and NupkgPath (stamped onto $Vm by
#   Invoke-DotnetToolAcquisition), so Install-Version forwards the Spec
#   straight through without needing $Vm in the closure.
# ---------------------------------------------------------------------------

function Get-DotnetToolsProvider {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Vm
    )

    $getDesiredFn       = ${function:Get-DotnetToolsDesiredVersions}
    $getInstalledFn     = ${function:Get-DotnetToolsInstalledVersions}
    $installVersionFn   = ${function:Install-DotnetToolVersion}
    $uninstallVersionFn = ${function:Uninstall-DotnetToolVersion}

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
        Name                    = 'dotnetTools'
        # Nested-provider marker. Value must equal a registered top-level
        # provider's Name; the reconciler reads this in its partition
        # step and routes dispatch through the children walker rather
        # than the main loop.
        ParentProvider          = 'dotnetSdk'
        'Get-DesiredVersions'   = $getDesired
        'Get-InstalledVersions' = $getInstalled
        'Install-Version'       = $installVersion
        'Uninstall-Version'     = $uninstallVersion
    }
}
