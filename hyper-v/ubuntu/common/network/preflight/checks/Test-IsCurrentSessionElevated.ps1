<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1.
#>

# ---------------------------------------------------------------------------
# Test-IsCurrentSessionElevated
#   Pure pass-through to the WindowsPrincipal API. Lifted out so
#   Pester can mock the predicate; the .NET static call itself
#   ([WindowsPrincipal]::IsInRole) cannot be mocked directly. The
#   preflight uses this as its very first check because Hyper-V /
#   Get-Net* cmdlets silently return nothing for a non-elevated
#   session, which downstream checks would misread as "switch
#   missing" and emit misleading errors.
# ---------------------------------------------------------------------------

function Test-IsCurrentSessionElevated {
    [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}
