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

    # Per-software sub-step timing. Acquisitions are network-dominated
    # (Adoptium and Microsoft CDN), so splitting the two buckets makes
    # an upstream regression attributable to its actual source instead
    # of being averaged across both. Sub-steps are pre-declared so
    # they appear as SKIPPED in the report when the corresponding
    # opt-in is absent.

    # Skip JDK acquisition when the operator's intent is "ensure none
    # installed" (javaDevKit absent / null / []) - no tarball is needed
    # for the reconciler's uninstall path, and we avoid an unnecessary
    # Adoptium API call on a cache miss. The host cache is shared across
    # VMs and stays untouched.
    if ($Vm.PSObject.Properties['javaDevKit'] -and
        $null -ne $Vm.javaDevKit -and
        @($Vm.javaDevKit).Count -gt 0) {
        Invoke-WithSubStepTimer `
            -Parent 'Host-side acquisitions' `
            -Name   'JDK' `
            -Action { Invoke-JdkAcquisition -Vm $Vm }
    }

    # Same ensure-none guard as JDK: skip the Microsoft release-metadata
    # call and the SDK tarball download when dotnetSdk is absent / null
    # / []. The reconciler's uninstall path reads the on-VM manifest, not
    # the host cache, so there is nothing to prefetch in that case.
    if ($Vm.PSObject.Properties['dotnetSdk'] -and
        $null -ne $Vm.dotnetSdk -and
        @($Vm.dotnetSdk).Count -gt 0) {
        # CacheDir is taken from $Vm.vhdPath so dotnet tarballs share the
        # same on-host cache as JDK tarballs (see the prefetch table in
        # README.md's provision.ps1 section). Invoke-DotnetSdkAcquisition
        # declares -CacheDir as Mandatory rather than defaulting it
        # internally so unit tests can target a scratch directory.
        Invoke-WithSubStepTimer `
            -Parent 'Host-side acquisitions' `
            -Name   'dotnet SDK' `
            -Action { Invoke-DotnetSdkAcquisition -Vm $Vm -CacheDir $Vm.vhdPath }
    }

    # dotnetTools acquirer. Runs AFTER the SDK acquirer so the SDK
    # tarball lands in the cache first - the on-VM install order
    # (SDK then tool) is enforced by the reconciler later, but
    # acquisition order is still meaningful when an operator inspects
    # a partial host cache state. Same vhdPath cache as the SDK
    # acquirer; the .nupkg/.lock.json artefacts live alongside the
    # SDK tarball with their own filename prefixes.
    #
    # Same ensure-none guard as the SDK branch: skip nuget.org calls
    # entirely when dotnetTools is absent / null / []. The reconciler's
    # uninstall path reads on-VM manifests, not the host cache, so a
    # cache miss in ensure-none mode would just waste a round trip.
    #
    # The cross-field constraint that dotnetTools requires dotnetSdk on
    # the same VM is enforced upstream by Assert-DotnetToolsField at
    # config-parse time - we do not re-validate here.
    if ($Vm.PSObject.Properties['dotnetTools'] -and
        $null -ne $Vm.dotnetTools -and
        @($Vm.dotnetTools).Count -gt 0) {
        Invoke-WithSubStepTimer `
            -Parent 'Host-side acquisitions' `
            -Name   'dotnet tools' `
            -Action { Invoke-DotnetToolAcquisition -Vm $Vm -CacheDir $Vm.vhdPath }
    }
}
