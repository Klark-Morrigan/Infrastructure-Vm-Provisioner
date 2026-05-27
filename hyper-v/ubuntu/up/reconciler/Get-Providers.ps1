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

    Nested providers (feature 42 Phase D, feature 43 Step 6B) live
    in the same returned array but carry a non-empty ParentProvider
    member naming their parent. Convention: a parent appears before
    its children in array order. The reconciler runs every provider
    in this order via the main loop (hybrid dispatch); the children
    walker stays in place only to gate child removal during a parent
    uninstall, so a child install that lives under the parent dir is
    torn down before the parent dir disappears. The first real
    consumer is `dotnetTools` (feature 43, nested under `dotnetSdk`).
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
        Get-JdkProvider         -Vm $Vm
        Get-DotnetSdkProvider   -Vm $Vm
        # Nested under dotnetSdk. Hybrid dispatch: it runs in the
        # reconciler's main loop like any other provider (so its
        # install pass fires) AND its Name registers in the by-Name
        # lookup the children walker uses during SDK uninstall.
        # Listed AFTER its parent so the convention "parent before
        # children" holds; the install loop order does not actually
        # matter (each iteration is self-contained) but the
        # convention makes Get-Providers readable as a tree.
        Get-DotnetToolsProvider -Vm $Vm
    )
}
