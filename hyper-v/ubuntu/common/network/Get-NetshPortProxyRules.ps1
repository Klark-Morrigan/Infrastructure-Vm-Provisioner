<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1.
#>

# ---------------------------------------------------------------------------
# Get-NetshPortProxyRules
#   Pure parser over `netsh interface portproxy show v4tov4`. netsh
#   has no native PowerShell binding for portproxy enumeration; its
#   textual output is the only surface. Lifted to its own function so
#   Pester can mock the rule list without invoking netsh, and so
#   other callers (status reporting, drift detection, etc.) reuse
#   the same parse.
#
#   netsh output shape (locale-dependent header text, but the rule
#   rows are stable):
#
#       Listen on ipv4:             Connect to ipv4:
#
#       Address         Port        Address         Port
#       --------------- ----------  --------------- ----------
#       127.0.0.1       2222        192.168.137.10  22
#
#   Returns an array of [PSCustomObject] with ListenAddress,
#   ListenPort (int), ConnectAddress, ConnectPort (int). Empty
#   array when no rules are configured (netsh emits only the
#   header lines, the regex matches none of them, so the filter
#   produces []).
# ---------------------------------------------------------------------------

function Get-NetshPortProxyRules {
    [CmdletBinding()]
    param()

    $raw = & netsh interface portproxy show v4tov4 2>$null
    if (-not $raw) { return @() }
    @($raw |
        Where-Object { $_ -match '^\s*\d+(\.\d+){3}\s+\d+\s+\d+(\.\d+){3}\s+\d+\s*$' } |
        ForEach-Object {
            $fields = ($_ -split '\s+') | Where-Object { $_ }
            [PSCustomObject]@{
                ListenAddress  = $fields[0]
                ListenPort     = [int]$fields[1]
                ConnectAddress = $fields[2]
                ConnectPort    = [int]$fields[3]
            }
        })
}
