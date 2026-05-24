<#
.SYNOPSIS
    Returns the ordered array of toolchain providers the reconciler
    dispatches against for each VM.

.DESCRIPTION
    Single registration point so the post-provisioning orchestrator does
    not have to know which providers exist. Order is the operator-visible
    dispatch order (the reconciler walks the array as-is).

    At step 5 this returns an empty array - the orchestrator call site
    exists, the manifest store is initialised on every VM, but no
    provider is wired in yet. The legacy Install-Jdk / Uninstall-Jdk
    dispatch on Invoke-VmPostProvisioning is still in charge of JDK
    until step 10 swaps it for a JdkProvider entry here.

    Why a function and not a module-scoped constant: providers compose
    scriptblocks that close over helpers loaded by dot-source, so
    deferring construction to call time keeps load order independent
    of registration order.
#>
function Get-Providers {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    # @() pipeline-unwraps to nothing on the empty case; the caller
    # wraps the call in @(...) to materialise an array regardless.
    # Later steps replace this with a concrete provider list.
    return @()
}
