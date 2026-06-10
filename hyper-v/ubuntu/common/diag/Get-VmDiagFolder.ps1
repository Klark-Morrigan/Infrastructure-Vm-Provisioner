<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1.
#>

# ---------------------------------------------------------------------------
# Get-VmDiagFolder
#   Single source of truth for the per-VM per-run diagnostics path:
#   <VmConfigPath>/diagnostics/<VmName>/<Timestamp>/. Every diag
#   producer (Invoke-SerialConsoleCapture's console.log,
#   Invoke-CloudInitDiagnostics's cloud-init-*.txt,
#   New-DiagnosticSshClientWrapper's ssh.log, Invoke-VmRuntimeDiag's
#   runtime-diag.log, and Assert-WorkloadReachableViaRouter's
#   router-side-probe.log) lands under the same folder for a single
#   provisioning run, so all artifacts for a given failure are
#   side-by-side without the operator having to correlate
#   timestamps.
#
#   Pure path constructor - callers create the directory themselves
#   if they need write access. Keeping the side-effect out of the
#   helper makes the function trivially testable (pure string in,
#   pure string out) and lets callers compose differently (some
#   want New-Item -Force unconditionally; others want a Test-Path
#   gate first).
# ---------------------------------------------------------------------------

function Get-VmDiagFolder {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $VmConfigPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $VmName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Timestamp
    )

    $path = Join-Path $VmConfigPath 'diagnostics'
    $path = Join-Path $path         $VmName
    $path = Join-Path $path         $Timestamp
    $path
}
