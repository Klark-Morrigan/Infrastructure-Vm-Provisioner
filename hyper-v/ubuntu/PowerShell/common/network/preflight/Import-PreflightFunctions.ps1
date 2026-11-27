<#
.NOTES
    Do not run this file directly. Dot-source it:
        . "<repo>\hyper-v\ubuntu\PowerShell\common\network\preflight\Import-PreflightFunctions.ps1"
#>

# The one list of what the host network preflight needs, so a file added for
# one entry point cannot be missing for another.
#
# The checks folder is globbed: every file in it is a check the orchestrator
# calls, so a new check needs no line here.
#
# Paths hang off $PSScriptRoot and this file declares no variable of its own:
# it is dot-sourced, so anything it declared would stay behind in the caller.

Get-ChildItem "$PSScriptRoot\checks" `
    -Filter '*.ps1' |
    ForEach-Object { . $_.FullName }

. "$PSScriptRoot\New-PreflightFinding.ps1"
. "$PSScriptRoot\Assert-PreflightFindings.ps1"
. "$PSScriptRoot\Assert-HostNetworkPreflight.ps1"
. "$PSScriptRoot\Invoke-HostNetworkPreflightCheck.ps1"

# Host reads the checks and the manual run lean on.
. "$PSScriptRoot\..\Get-IcsHostAddress.ps1"
. "$PSScriptRoot\..\Get-InternetRoute.ps1"
. "$PSScriptRoot\..\Get-VmAdapterIPv4.ps1"
. "$PSScriptRoot\..\Resolve-WanAdapterName.ps1"
