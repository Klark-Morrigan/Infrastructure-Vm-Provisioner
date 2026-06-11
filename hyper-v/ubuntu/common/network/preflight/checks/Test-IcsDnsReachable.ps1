<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1.
#>

# ---------------------------------------------------------------------------
# Test-IcsDnsReachable
#   Pass-through predicate over Resolve-DnsName so tests can mock the
#   probe (the real cmdlet hits the network and is not deterministic
#   in CI). Any error - RST, timeout, NXDOMAIN, missing module -
#   reduces to $false because the only thing the caller cares about
#   is "the path answers cleanly". A proxy returning NXDOMAIN is
#   just as broken as one timing out, since the request name is a
#   stable real-world host we control the choice of (archive.ubuntu.com).
# ---------------------------------------------------------------------------

function Test-IcsDnsReachable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Server
    )

    try {
        $result = Resolve-DnsName -Name 'archive.ubuntu.com' `
                                  -Server $Server `
                                  -DnsOnly `
                                  -ErrorAction Stop
        return [bool]$result
    } catch {
        return $false
    }
}
