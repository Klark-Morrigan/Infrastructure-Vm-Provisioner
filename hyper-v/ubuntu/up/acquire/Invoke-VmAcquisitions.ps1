<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1 after the
    per-software acquirer files are loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-VmAcquisitions
#   Per-VM host-side acquisition orchestrator. Inspects the VM definition
#   and dispatches to each per-software acquirer whose opt-in field is set.
#   Self-skips silently when no opt-in fields apply.
#
#   The acquisition layer has no shared transport to amortize (each
#   acquirer is just "fetch X to host cache, attach $vm._xPath"). The
#   orchestrator exists purely to keep provision.ps1's per-VM loop a
#   one-liner as more acquirers are added, so the high-level provisioning
#   sequence stays readable.
#
#   Mirrors Invoke-VmPostProvisioning's "one orchestrator + N step
#   functions" shape on the post-VM side. Each acquirer is self-contained
#   and may not depend on another acquirer's output.
# ---------------------------------------------------------------------------

function Invoke-VmAcquisitions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Vm
    )

    # Skip JDK acquisition when the operator's intent is "ensure none
    # installed" (javaDevKit absent / null / []) - no tarball is needed
    # for the reconciler's uninstall path, and we avoid an unnecessary
    # Adoptium API call on a cache miss. The host cache is shared across
    # VMs and stays untouched.
    if ($Vm.PSObject.Properties['javaDevKit'] -and
        $null -ne $Vm.javaDevKit -and
        @($Vm.javaDevKit).Count -gt 0) {
        Invoke-JdkAcquisition -Vm $Vm
    }

    # Same ensure-none guard as JDK: skip the Microsoft release-metadata
    # call and the SDK tarball download when dotnetSdk is absent / null
    # / []. The reconciler's uninstall path reads the on-VM manifest, not
    # the host cache, so there is nothing to prefetch in that case.
    if ($Vm.PSObject.Properties['dotnetSdk'] -and
        $null -ne $Vm.dotnetSdk -and
        @($Vm.dotnetSdk).Count -gt 0) {
        Invoke-DotnetSdkAcquisition -Vm $Vm
    }
}
