<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    the reconciler orchestrator and by provider composition helpers
    (e.g. Get-JdkProvider, Get-DotnetSdkProvider).
#>

# ---------------------------------------------------------------------------
# Provider contract (IToolchainProvider, conceptually)
#
#   A "toolchain provider" is a [PSCustomObject] (or hashtable) describing
#   how to reconcile one JSON field on a VM definition (e.g. 'javaDevKit',
#   'dotnetSdk') against what is actually installed on the VM.
#
#   The orchestrator (Invoke-ToolchainReconciliation, step 4) walks the
#   registered providers in array order and, for each one, calls the four
#   scriptblock members below.
#
#   Required members:
#
#     Name                  [string]
#         The JSON sub-field this provider consumes. Examples:
#         'javaDevKit', 'dotnetSdk'. Used in log lines and in aggregate
#         error messages so an operator can tell which provider failed.
#
#     Get-DesiredVersions   [scriptblock] ($vmConfig)
#         Parses the relevant JSON sub-field on $vmConfig.
#           - $null   -> the sub-field is absent. The orchestrator
#                        SKIPS this provider entirely (does not even
#                        query installed versions).
#           - @()     -> the sub-field is present but explicitly empty
#                        (null or []). Reconcile to "ensure none
#                        installed".
#           - array   -> typed spec objects. Reconcile to exactly this
#                        set.
#
#     Get-InstalledVersions [scriptblock] ($sshClient)
#         Returns an array of typed installed records:
#             { Provider, Version, InstallPath, ManifestPath }
#         Empty array when nothing is installed. Discovery is driven
#         by sidecar manifests under
#         /var/lib/infra-provisioner/manifests/ (see step 2).
#
#     Install-Version       [scriptblock] ($sshClient, $server, $spec)
#         Installs one version end-to-end and writes its manifest.
#         Throws on failure. The orchestrator captures per-provider
#         failures and continues with the next provider.
#
#     Uninstall-Version     [scriptblock] ($sshClient, $installed)
#         Uninstalls one version using the manifest pointed at by
#         $installed.ManifestPath as the truth source for owned paths,
#         symlinks, and profile.d scripts. Throws on failure.
#
#   Optional members:
#
#     ParentProvider        [string]
#         When set, marks this provider as a NESTED provider whose
#         lifecycle is gated by another (parent) provider's. The
#         orchestrator does NOT dispatch nested providers in its
#         top-level loop; they are invoked only through the children
#         walker (see Invoke-ToolchainReconciliation), which fires their
#         Uninstall-Version when a parent manifest's `children` array
#         points at them. Value must equal a registered top-level
#         provider's Name. First real consumer is feature 43
#         (dotnet nuget global tools); v1 of this feature ships the
#         walker but registers zero nested providers.
#
#   Assert-ToolchainProvider is a small "shape check" the orchestrator
#   runs on every provider before dispatching to it, so a malformed
#   provider object fails loud with a member-by-member message rather
#   than yielding an opaque ScriptBlock invocation error later.
# ---------------------------------------------------------------------------

# Each entry is the required member name and the type its value must
# satisfy. Kept as data (not unrolled code) so the asserter walks the
# list uniformly and adding a future required member is a one-line
# edit.
$script:ToolchainProviderRequiredMembers = @(
    @{ Name = 'Name';                  Type = [string]      },
    @{ Name = 'Get-DesiredVersions';   Type = [scriptblock] },
    @{ Name = 'Get-InstalledVersions'; Type = [scriptblock] },
    @{ Name = 'Install-Version';       Type = [scriptblock] },
    @{ Name = 'Uninstall-Version';     Type = [scriptblock] }
)

function Assert-ToolchainProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Provider
    )

    if ($null -eq $Provider) {
        throw "Toolchain provider must not be null."
    }

    # Accept both PSCustomObject (the common composition shape) and
    # hashtable (handy for ad-hoc / inline registrations).
    $isHashtable    = $Provider -is [hashtable]
    $isPsCustomObj  = $Provider -is [System.Management.Automation.PSCustomObject]
    if (-not ($isHashtable -or $isPsCustomObj)) {
        throw (
            "Toolchain provider must be a [PSCustomObject] or [hashtable]; " +
            "got [$($Provider.GetType().FullName)]."
        )
    }

    foreach ($member in $script:ToolchainProviderRequiredMembers) {
        $name         = $member.Name
        $expectedType = $member.Type

        # Member presence: hashtables use ContainsKey; PSCustomObjects
        # use the Properties collection. PSObject.Properties does not
        # see hashtable keys (a strict-mode foot-gun documented in
        # the user's memory index), so the two paths are kept
        # explicit.
        $hasMember = if ($isHashtable) {
            $Provider.ContainsKey($name)
        } else {
            $null -ne $Provider.PSObject.Properties[$name]
        }

        if (-not $hasMember) {
            throw "Toolchain provider is missing required member '$name'."
        }

        $value = $Provider.$name

        # Reject $null explicitly; an empty string Name or a $null
        # scriptblock would otherwise pass the type check on some
        # PowerShell hosts and only blow up at dispatch time.
        if ($null -eq $value) {
            throw "Toolchain provider member '$name' must not be null."
        }

        if ($name -eq 'Name') {
            if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
                throw (
                    "Toolchain provider member 'Name' must be a non-empty " +
                    "string; got [$($value.GetType().FullName)]."
                )
            }
            continue
        }

        if ($value -isnot $expectedType) {
            throw (
                "Toolchain provider member '$name' must be a " +
                "[$($expectedType.FullName)]; got [$($value.GetType().FullName)]."
            )
        }
    }
}
