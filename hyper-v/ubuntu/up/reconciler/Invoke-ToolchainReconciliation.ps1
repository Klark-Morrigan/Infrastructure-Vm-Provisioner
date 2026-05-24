<#
.SYNOPSIS
    Walks registered toolchain providers, diffs desired vs installed, and
    dispatches uninstall-then-install for each provider in array order.

.DESCRIPTION
    The orchestrator visits each provider in the order it appears in
    -Providers (which the caller derives from the VM JSON's declaration
    order; see step 5). For each provider it:

        1. Shape-checks the provider (Assert-ToolchainProvider).
        2. Calls Get-DesiredVersions($Vm). $null means "skip this provider
           entirely" - the installed query is not even issued.
        3. Calls Get-InstalledVersions($SshClient).
        4. Computes the diff via Get-ProvisioningPlan.
        5. Calls Uninstall-Version for each ToUninstall record.
        6. Calls Install-Version for each ToInstall spec.

    Per-provider transactional boundary: a failure inside one provider is
    caught, logged with the provider's Name, and recorded in a failure
    list; the orchestrator continues with the next provider so one broken
    toolchain does not silently block reconciliation of the others. At
    the end, if any provider failed, a single aggregate exception is
    thrown naming each failed provider plus its inner message.

    Why uninstall-before-install within a provider: a version swap
    (e.g. 21.0.5 -> 21.0.6) frees /usr/local/bin/<binary> symlinks and
    /etc/profile.d/<provider>.sh before the new install tries to claim
    them. Installing first would race against the manifest-driven
    Remove-VmSymlink and leave the host pointing at the old version.

.PARAMETER SshClient
    An open SSH.NET client to the target VM. Passed straight through to
    each provider's Get-InstalledVersions / Install-Version /
    Uninstall-Version.

.PARAMETER Server
    The host file-server endpoint (the same object handed to other
    post-provisioning steps). Threaded through to Install-Version so
    providers can stream tarballs from the host cache.

.PARAMETER Vm
    The VM definition (PSCustomObject parsed from the VM JSON). Handed
    to Get-DesiredVersions so each provider can read its own sub-field.

.PARAMETER Providers
    Ordered array of provider objects. Order is the operator's
    declaration order from the JSON, preserved by the caller. An empty
    array is allowed and is a no-op (useful in step 5 before any
    provider is registered).
#>
function Invoke-ToolchainReconciliation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Server,

        [Parameter(Mandatory)]
        [object] $Vm,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Providers
    )

    # Per-provider failure log. We capture { ProviderName, Message } and
    # surface the lot as a single aggregate at the end so the operator
    # sees every broken toolchain in one error rather than chasing them
    # one provision-run at a time.
    $failures = New-Object System.Collections.Generic.List[object]

    foreach ($provider in $Providers) {

        # Resolve the provider Name up-front for log lines. If the
        # provider object is so malformed that even Name is missing,
        # Assert-ToolchainProvider below will surface that; meanwhile
        # the fallback keeps log output safe.
        $providerName = if ($provider -and $provider.Name) {
            [string]$provider.Name
        } else {
            '<unknown>'
        }

        try {
            # Shape check first so a typo in a provider object fails with
            # a member-by-member message instead of an opaque scriptblock
            # invocation error mid-dispatch.
            Assert-ToolchainProvider -Provider $provider

            Write-Host "  [reconciler] $providerName : computing desired ..."
            $desired = & $provider.'Get-DesiredVersions' $Vm

            if ($null -eq $desired) {
                # Sub-field absent on the VM JSON. Per the contract, do
                # not even query installed versions - the operator's
                # intent is "this provider has nothing to say about this
                # VM" rather than "ensure none installed".
                Write-Host "  [reconciler] $providerName : skipped (no desired set)"
                continue
            }

            Write-Host "  [reconciler] $providerName : querying installed ..."
            $installed = & $provider.'Get-InstalledVersions' $SshClient

            $plan = Get-ProvisioningPlan `
                        -DesiredVersions   $desired `
                        -InstalledVersions $installed `
                        -ProviderName      $providerName

            $toUninstall = @($plan.ToUninstall)
            $toInstall   = @($plan.ToInstall)

            Write-Host (
                "  [reconciler] $providerName : " +
                "uninstall=$($toUninstall.Count) " +
                "install=$($toInstall.Count) " +
                "noop=$(@($plan.NoOp).Count)"
            )

            # Uninstall-then-install: see header docstring for the
            # symlink / profile.d ownership reasoning.
            foreach ($record in $toUninstall) {
                & $provider.'Uninstall-Version' $SshClient $record
            }

            foreach ($spec in $toInstall) {
                & $provider.'Install-Version' $SshClient $Server $spec
            }
        }
        catch {
            # Per-provider boundary. Log here so the operator sees the
            # failure in real time, then record the message so the
            # aggregate at the end carries the same detail.
            $message = $_.Exception.Message
            Write-Warning "  [reconciler] $providerName : failed - $message"
            $failures.Add([PSCustomObject]@{
                ProviderName = $providerName
                Message      = $message
            })
        }
    }

    if ($failures.Count -gt 0) {
        # One aggregate error so the caller gets a single failure surface
        # rather than a stream of warnings that may be lost in a long
        # provision run's output.
        $lines = $failures | ForEach-Object {
            "  - $($_.ProviderName): $($_.Message)"
        }
        throw (
            "Invoke-ToolchainReconciliation: $($failures.Count) provider(s) " +
            "failed:`n" + ($lines -join "`n")
        )
    }
}
