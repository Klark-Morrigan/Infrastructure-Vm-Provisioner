<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1.
#>

# ---------------------------------------------------------------------------
# Invoke-WslShell
#   Thin pass-through to `wsl -d <distro> -- bash -c <command>` so
#   tests can mock the WSL execution without invoking the real
#   binary. Returns native stdout/stderr; sets $LASTEXITCODE.
#
#   Lifted to its own file so callers besides Test-WslRouterReachability
#   (future preflight checks, smoke probes, ops scripts) can reuse the
#   same Pester-mockable boundary instead of each rolling their own
#   `& wsl -d ... bash -c ...` and tripping the same shell-escaping
#   pitfalls.
# ---------------------------------------------------------------------------

function Invoke-WslShell {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Distro,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Command
    )
    & wsl -d $Distro -- bash -c $Command
}
