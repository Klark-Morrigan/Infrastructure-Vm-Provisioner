<#
.SYNOPSIS
    Returns the ordered array of toolchain providers the reconciler
    dispatches against for one VM.

.DESCRIPTION
    Single registration point so the post-provisioning orchestrator does
    not have to know which providers exist. Order is the operator-visible
    dispatch order (the reconciler walks the array as-is).

    Takes -Vm so each provider can capture the VM via closure - in
    particular the JDK provider needs $Vm._jdkTarballPath and
    $Vm._jdkResolvedVersion (populated by Invoke-JdkAcquisition) to
    bridge from the reconciler's ($SshClient, $Server, $Spec)
    Install-Version contract to Install-JdkVersion's TarballPath /
    ResolvedVersion parameters. See Get-JdkProvider.ps1 for the
    closure mechanics.

    Why a function and not a module-scoped constant: providers compose
    scriptblocks that close over helpers loaded by dot-source AND over
    per-VM state, so deferring construction to call time keeps load
    order independent of registration order and lets each call snapshot
    a different VM.

    Nested providers (feature 42 Phase D) live in the same returned
    array but carry a non-empty ParentProvider member naming their
    parent. The reconciler partitions on that field: top-level
    providers run in the main loop in array order, nested providers
    are dispatched only by the children walker when a parent manifest's
    `children` array refers to them by Name. v1 of feature 42 ships
    the walker but registers zero nested providers; the first real
    consumer (a global nuget tools provider under DotnetSdkProvider)
    lands in feature 43.
#>
function Get-Providers {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [object] $Vm
    )

    # Bare array literal - PowerShell's output stream unrolls it on the
    # way back so the caller's `@(Get-Providers ...)` wrapper sees a
    # flat array of providers. Order is the reconciler's dispatch order
    # (JSON-declaration order between providers); JDK lands first
    # because it was the first reconciler-owned toolchain and dotnet
    # SDK appended below.
    return @(
        Get-JdkProvider       -Vm $Vm
        Get-DotnetSdkProvider -Vm $Vm
    )
}
