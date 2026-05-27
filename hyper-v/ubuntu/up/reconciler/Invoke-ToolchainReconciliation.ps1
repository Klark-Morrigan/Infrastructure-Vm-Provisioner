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

    Providers carrying a non-empty ParentProvider member are NESTED
    providers: they run in this same loop alongside top-level
    providers, in the order they appear in -Providers (convention:
    parent before its children). The ParentProvider field is pure
    metadata used by the children walker (see below) to look the
    nested provider up by Name when a parent manifest's `children`
    array refers to it during parent uninstall. The walker still
    handles the parent-uninstall ordering case; the main loop
    handles every install and every standalone (non-parent-driven)
    uninstall. A nested provider's Name must equal the value used
    in its parents' manifest `children[].provider` field for the
    walker lookup to succeed.

.PARAMETER OnProviderComplete
    Optional scriptblock invoked once per provider after its
    diff/install/uninstall block finishes (regardless of success or
    failure). Receives ($providerName, $elapsedMs, $hadError) so a
    caller can feed per-provider durations into a timing report
    without the orchestrator having to know about that subsystem.
    Fires for every provider in -Providers, including nested ones,
    since the hybrid dispatch runs all providers in this loop.
    A throwing callback is swallowed and surfaced as a warning - it
    must not mask a real provider failure or interfere with dispatch
    of the remaining providers.

.NOTES
    Hybrid dispatch (feature 43 Step 6B). Nested providers run in
    this same main loop just like top-level providers - their
    install pass, and any standalone uninstall that is not driven
    by a parent's teardown, happen during their own iteration. The
    children walker (originally Phase D of feature 42) is retained
    for the parent-uninstall ordering case only: before invoking a
    parent provider's Uninstall-Version on an installed record, the
    orchestrator reads that record's manifest and, for every entry
    in its `children` array, dispatches the matching nested
    provider's Uninstall-Version first. This ordering matters: a
    child install typically lives UNDER its parent's install dir
    (e.g. a dotnet global tool inside the SDK install root), so
    removing the parent first would orphan the child manifest and
    leave nothing for the next reconcile to clean up. When no
    nested provider is registered for a child entry the walker logs
    a warning and proceeds - the alternative (throw) would leave
    the parent forever installed once the child provider is
    unregistered, which is the worse failure mode for an operator
    who just wants their VM clean.

    Why not an install-side symmetric walker: it would miss the
    "parent NoOp, child new version" case - a NoOp parent does not
    fire Install-Version, so the walker would never run and the
    child would stay stuck on the old pin. The main-loop pass
    handles that case naturally because the child's own iteration
    sees its own desired/installed diff regardless of what the
    parent decided.
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
        [object[]] $Providers,

        # Optional per-provider completion callback. See the
        # parameter docstring above for the contract. Default $null
        # means "no callback" and the orchestrator behaves exactly as
        # before this parameter was added.
        [Parameter()]
        [scriptblock] $OnProviderComplete = $null
    )

    # Per-provider failure log. We capture { ProviderName, Message } and
    # surface the lot as a single aggregate at the end so the operator
    # sees every broken toolchain in one error rather than chasing them
    # one provision-run at a time.
    $failures = New-Object System.Collections.Generic.List[object]

    # Build the by-Name lookup the children walker consumes during
    # parent uninstall. Every provider (top-level or nested) goes into
    # the index so the walker can resolve any child reference, but the
    # main loop below iterates ALL providers in the supplied order -
    # nested providers no longer get partitioned out. Hybrid dispatch:
    # nested providers run their own install/standalone-uninstall pass
    # in the main loop just like top-level providers; the walker keeps
    # the parent-uninstall ordering case so a child install that lives
    # under the parent's install dir is removed before the parent dir
    # disappears. Last-write-wins on duplicate Names is acceptable:
    # provider registration is operator-controlled and a duplicate Name
    # would trip the parent's manifest schema sooner or later. Keep
    # this loop minimal.
    $nestedProvidersByName = @{}
    foreach ($candidate in $Providers) {
        if ($null -ne $candidate -and $candidate.Name) {
            $nestedProvidersByName[[string]$candidate.Name] = $candidate
        }
    }

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

        # Per-provider stopwatch. Brackets the WHOLE per-provider
        # block (shape check, diff, install/uninstall, children
        # walker) so a callback consumer can attribute every cost
        # back to the provider that incurred it - including the
        # shape-check time of a malformed provider, which would
        # otherwise look like phantom orchestrator overhead.
        $providerSw = [System.Diagnostics.Stopwatch]::StartNew()
        $providerHadError = $false

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

            # Render version arrays in single quotes per entry so a
            # whitespace-only difference (trailing CR, leading space)
            # is obvious in the log - a bare comma-join would hide it.
            $desiredVersionsStr = (
                @($desired | ForEach-Object { "'" + [string]$_.Version + "'" }) -join ', '
            )
            $installedVersionsStr = (
                @($installed | ForEach-Object { "'" + [string]$_.Version + "'" }) -join ', '
            )
            Write-Host (
                "  [reconciler] $providerName : " +
                "uninstall=$($toUninstall.Count) " +
                "install=$($toInstall.Count) " +
                "noop=$(@($plan.NoOp).Count)  " +
                "desired=[$desiredVersionsStr] " +
                "installed=[$installedVersionsStr]"
            )

            # Uninstall-then-install: see header docstring for the
            # symlink / profile.d ownership reasoning.
            foreach ($record in $toUninstall) {
                # Children walker runs FIRST so a child install (which
                # may live under the parent's install dir) is torn down
                # by its own provider before the parent's
                # Uninstall-Version removes the directory underneath it.
                Invoke-ToolchainChildrenUninstall `
                    -SshClient             $SshClient `
                    -ParentInstalled       $record `
                    -ParentProviderName    $providerName `
                    -NestedProvidersByName $nestedProvidersByName

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
            $providerHadError = $true
            $message = $_.Exception.Message
            Write-Warning "  [reconciler] $providerName : failed - $message"
            $failures.Add([PSCustomObject]@{
                ProviderName = $providerName
                Message      = $message
            })
        }
        finally {
            $providerSw.Stop()
            if ($null -ne $OnProviderComplete) {
                # Callback failures must not bring down the orchestrator
                # - they would mask the per-provider boundary contract.
                # Surface them as a warning so a buggy callback is still
                # visible, but keep dispatching the remaining providers.
                try {
                    & $OnProviderComplete `
                        $providerName `
                        $providerSw.ElapsedMilliseconds `
                        $providerHadError
                }
                catch {
                    Write-Warning (
                        "  [reconciler] OnProviderComplete callback " +
                        "threw for '$providerName': $($_.Exception.Message)"
                    )
                }
            }
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

<#
.SYNOPSIS
    Reads a parent's manifest and dispatches Uninstall-Version on every
    registered nested provider that owns one of its children.

.DESCRIPTION
    The children contract is intentionally narrow: each entry in the
    parent manifest's `children` array is { provider, manifestPath },
    where `provider` matches a registered nested provider's Name and
    `manifestPath` is the absolute path to the child's own manifest on
    the VM. The walker reads that child manifest, synthesises the same
    Installed record shape that Get-InstalledVersions would produce
    (Provider, Version, InstallPath, ManifestPath), and hands it to
    the child provider's Uninstall-Version.

    Failure semantics:
      - Parent manifest has no `children` member, or it is empty:
        no-op.
      - Child entry refers to a provider that is NOT registered as a
        nested provider: log a warning and proceed. Throwing would
        leave the parent forever installed once the operator removes
        the child's provider registration, which is the worse failure
        mode.
      - Child provider's Uninstall-Version throws: the exception
        propagates so the parent provider's per-provider boundary in
        the orchestrator catches it. The parent's Uninstall-Version
        therefore does NOT run, which keeps the parent's manifest in
        place as the recovery anchor for the next reconciler run.

.PARAMETER SshClient
    Forwarded to Read-VmManifest and to the child provider's
    Uninstall-Version.

.PARAMETER ParentInstalled
    Installed record for the parent (carrying ManifestPath). The
    record itself is opaque to the walker - only ManifestPath is read.

.PARAMETER ParentProviderName
    Used only for log lines so the operator can correlate the warning
    back to a parent toolchain.

.PARAMETER NestedProvidersByName
    Lookup of nested providers, keyed by Name. Populated by the
    orchestrator from the providers carrying a ParentProvider member.
#>
function Invoke-ToolchainChildrenUninstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]    $SshClient,
        [Parameter(Mandatory)] [object]    $ParentInstalled,
        [Parameter(Mandatory)] [string]    $ParentProviderName,
        [Parameter(Mandatory)] [hashtable] $NestedProvidersByName
    )

    $parentManifestPath = [string]$ParentInstalled.ManifestPath
    if ([string]::IsNullOrEmpty($parentManifestPath)) {
        # Defensive: an Installed record without ManifestPath cannot
        # have children. Silently no-op rather than throw because the
        # contract for Installed records is enforced at provider level
        # (Get-InstalledVersions), not here.
        return
    }

    $parentManifest = Read-VmManifest -SshClient $SshClient -Path $parentManifestPath

    $childrenProp = $parentManifest.PSObject.Properties['children']
    if ($null -eq $childrenProp) { return }

    # Pipeline can unroll a single-element array back to a scalar under
    # strict mode; wrap in @(...) so .Count is meaningful even for one
    # child.
    $children = @($childrenProp.Value)
    if ($children.Count -eq 0) { return }

    foreach ($child in $children) {
        $childProviderName = [string]$child.provider
        $childManifestPath = [string]$child.manifestPath

        if (-not $NestedProvidersByName.ContainsKey($childProviderName)) {
            Write-Warning (
                "  [reconciler] $ParentProviderName : children walker - " +
                "no nested provider registered for '$childProviderName' " +
                "(child manifest '$childManifestPath'); leaving in place."
            )
            continue
        }

        $childProvider = $NestedProvidersByName[$childProviderName]
        $childManifest = Read-VmManifest -SshClient $SshClient -Path $childManifestPath

        # Synthesise the Installed record shape so the nested provider
        # sees the same contract its own Get-InstalledVersions would
        # emit. InstallPath comes from ownedPaths[0] by the same
        # convention JdkProvider.Get-InstalledVersions uses.
        $childOwnedPaths = @($childManifest.ownedPaths)
        $childInstallPath = if ($childOwnedPaths.Count -gt 0) {
            [string]$childOwnedPaths[0]
        } else {
            ''
        }

        $childInstalled = [PSCustomObject]@{
            Provider     = $childProviderName
            Version      = [string]$childManifest.version
            InstallPath  = $childInstallPath
            ManifestPath = $childManifestPath
        }

        Write-Host (
            "  [reconciler] $ParentProviderName : uninstalling child " +
            "'$childProviderName' v$($childInstalled.Version) first"
        )
        & $childProvider.'Uninstall-Version' $SshClient $childInstalled
    }
}
