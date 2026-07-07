<#
.SYNOPSIS
    Installs and imports every PowerShell module the Infrastructure-Vm-Provisioner
    entry-point scripts need.

.DESCRIPTION
    Centralised so each entry-point (provision.ps1, deprovision.ps1, ...)
    dot-sources this file once instead of repeating the same install/import
    block. Intentionally not a function: dot-sourcing this script imports
    every required module into the caller's scope, which is what the
    entry-points and their dot-sourced helpers expect.

    Step 1 - NuGet provider: PowerShellGet uses it to download from PSGallery.
             Included even though it's idempotent so a cold machine doesn't
             need a separate setup step.

    Step 2 - Common.PowerShell: the chicken-and-egg case. It supplies
             Invoke-ModuleInstall used by every install below, so it cannot
             install itself - the inline guard is unavoidable.

    Step 3 - Everything else flows through Invoke-ModuleInstall.

.NOTES
    Setup-secrets.ps1 is responsible for the encrypted SecretStore vault and
    its provider modules; that side of the world is not duplicated here.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Install-PowerShellCommonWithRetry
#   The chicken-and-egg case: Invoke-ModuleInstall (which has retry built
#   in) lives inside Common.PowerShell, so it cannot be used to install
#   Common.PowerShell itself. A small inline retry wrapper here covers
#   that single bootstrap call. All later Invoke-ModuleInstall calls below
#   get retry for free.
#
#   Defaults mirror Invoke-ModuleInstall's: 6 attempts, exponential 10 s ->
#   20 -> 40 -> 80 -> 160, capped at 300 s (5 min). Total wait ~5 min
#   before giving up - long enough to ride out a transient PSGallery
#   resolution blip, short enough that a real outage fails the run.
# ---------------------------------------------------------------------------
function Install-PowerShellCommonWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [Version] $MinimumVersion,
        [int] $MaxAttempts         = 6,
        [int] $InitialDelaySeconds = 10,
        [int] $MaxDelaySeconds     = 300
    )
    $delay = $InitialDelaySeconds
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            # -ErrorAction Stop promotes PSGallery "Unable to resolve
            # package source" (a non-terminating error by default) to a
            # terminating one so the catch block can retry it.
            Install-Module Common.PowerShell `
                -MinimumVersion $MinimumVersion `
                -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            return
        }
        catch {
            if ($attempt -ge $MaxAttempts) { throw }
            Write-Warning (
                "Install-Module Common.PowerShell failed " +
                "(attempt $attempt/$MaxAttempts): " +
                "$($_.Exception.Message). Retrying in ${delay}s ..."
            )
            Start-Sleep -Seconds $delay
            $delay = [Math]::Min($delay * 2, $MaxDelaySeconds)
        }
    }
}

# Step 1 - NuGet provider
$_nuget = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $_nuget -or $_nuget.Version -lt [Version]'2.8.5.201') {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 `
        -Scope CurrentUser -Force -ForceBootstrap | Out-Null
}

# Step 2 - Common.PowerShell (chicken-and-egg bootstrap)
# Floor is 9.2.0: that release adds Export-PhaseTimingTree, the export
# counterpart of Write-PhaseTimingReport that provision.ps1's outer finally
# calls on the TIMING_TREE_OUTPUT_PATH opt-in to hand its timing tree to a
# parent orchestrator. 9.1.0 shipped the 2-level phase-timing compat shims
# (Initialize-PhaseTimings / Invoke-WithPhaseTimer / Invoke-WithSubStepTimer /
# Add-SubStepDuration / Write-PhaseTimingReport) provision.ps1 also consumes.
# Subsumes the older 8.1.0 floor (Infrastructure.Network.Windows, installed in
# step 3, declares Common.PowerShell >= 8.1.0 in its RequiredModules). Because
# the bootstrap imports Common.PowerShell into the session here, loading an
# older version first would collide with those requirements; loading 9.2.0 up
# front keeps a single compatible version live.
$_common = Get-Module -ListAvailable -Name Common.PowerShell |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $_common -or $_common.Version -lt [Version]'9.2.0') {
    Install-PowerShellCommonWithRetry -MinimumVersion '9.2.0'
    # Re-query so the comparison below uses the freshly installed version.
    $_common = Get-Module -ListAvailable -Name Common.PowerShell |
        Sort-Object Version -Descending | Select-Object -First 1
}
# Reload only when the loaded state differs from the target (multiple
# versions live, or wrong version live). Mirrors the conditional in
# Invoke-ModuleInstall - inlined here because the bootstrap installs
# the very module that defines that function.
$_loaded = @(Get-Module -Name Common.PowerShell)
if ($_loaded.Count -ne 1 -or $_loaded[0].Version -ne $_common.Version) {
    if ($_loaded) { $_loaded | Remove-Module -Force }
    Import-Module Common.PowerShell -Force -ErrorAction Stop
}

# Step 3 - Everything else
# Infrastructure.HyperV provides Test-VmSshPort (used by create-vm.ps1's
# cloud-init readiness poll) and New-VmSshClient / Invoke-SshClientCommand /
# Invoke-WithVmFileServer / Add-VmFileServerFile (used by the out-of-band
# post-provisioning file transfers and software installs).
# >= 1.3.0 is required for Test-VmSshCredential (the router credential gate
# in create-vm.ps1 delegates its connect + auth-vs-transient classification
# to it); 1.2.0 added New-VmSshClient's -KeepAliveInterval and
# New-RetryingSshClientWrapper, which the post-provisioning session relies
# on to survive a transient drop on the flaky NAT/ICS path.
Invoke-ModuleInstall -ModuleName 'Infrastructure.HyperV' -MinimumVersion '1.3.0'

# Infrastructure.Network.Windows hosts the Windows-only host-network
# helpers the preflight + step 4 setup rely on: Reset-IcsSharing,
# Set-RouterSshPortProxy(+Firewall), Get-NetshPortProxyRules,
# Test-HostNetworkProfileSetting, Test-IcsDnsReachable,
# Test-IcsDnsProxyReachable, Test-WslRouterReachability. Auto-pulls
# Infrastructure.Wsl via its RequiredModules manifest entry, so
# Invoke-WslShell becomes available without an explicit install
# call here.
# Floor 1.3.0: the host-network preflight + its manual wrapper resolve
# the Wi-Fi adapter via Get-WirelessNetAdapter (added in 1.3.0). Subsumes
# the 1.1.0 floor (Get-IcsDnsFailureDiagnostics, which turns a wedged ICS
# proxy into a single named next-step instead of a manual checklist) and
# the older 0.6.0 floor (Set-RouterSshPortProxyFirewall's reboot-stable
# WSL-NAT-range scoping).
Invoke-ModuleInstall -ModuleName 'Infrastructure.Network.Windows' -MinimumVersion '1.3.0'

# Infrastructure.Wsl provides Invoke-WslShell (used by
# Test-WslRouterReachability) and Assert-Wsl2Ready / Assert-WslHasBash
# (gates for any wsl-using flow). Moved out of Common.PowerShell at
# 7.0.0 so a fresh provisioner host needs both modules now.
Invoke-ModuleInstall -ModuleName 'Infrastructure.Wsl' -MinimumVersion '0.1.0'

# Posh-SSH is loaded only for its bundled Renci.SshNet.dll - the SSH.NET
# types that New-VmSshClient instantiates. Posh-SSH's own cmdlets are not
# used (ConnectionInfoGenerator in Posh-SSH 3.x drops algorithm entries,
# breaking key exchange against OpenSSH 9.x on Ubuntu 24.04). Same pattern
# as Infrastructure-E2E's vm-provisioning tests.
Invoke-ModuleInstall -ModuleName 'Posh-SSH'

# Infrastructure.Secrets is used by setup-secrets.ps1 to seed the vault;
# included here so setup-secrets can dot-source this helper too. The
# SecretManagement provider modules are imported (not installed) by
# provision.ps1 itself - it expects them on the machine already.
Invoke-ModuleInstall -ModuleName 'Infrastructure.Secrets' -MinimumVersion '3.0.1'
