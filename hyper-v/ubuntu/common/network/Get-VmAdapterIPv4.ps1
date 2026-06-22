<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1.
#>

# ---------------------------------------------------------------------------
# Get-VmAdapterIPv4
#   Single source of truth for "given a sequence of Hyper-V
#   VMNetworkAdapter objects, return the IPv4 strings they carry".
#   Two call shapes use this:
#     - Assert-HostNetworkPreflight (IP-collision check between host
#       vNIC and every VM on the same switch).
#     - Get-VmRuntimeDiagHostSide (Get-NetNeighbor + route lookup for
#       every IPv4 the VM has held).
#
#   Three transformations packaged together:
#     1. Filter to adapters that actually carry an IPAddresses
#        property. Hyper-V Integration Services returns
#        VMNetworkAdapter objects WITHOUT that property when the
#        KVP daemon has not published yet (stopped VMs, fresh
#        boots, broken integration services, Management OS
#        adapters returned by Get-VMNetworkAdapter -All). Under
#        Set-StrictMode -Version Latest + ErrorActionPreference=Stop
#        (the provisioner's default), reading a missing property
#        TERMINATES the script. The PSObject.Properties guard
#        avoids that.
#     2. Expand IPAddresses into individual address strings.
#     3. Keep only IPv4 dotted-quads. IPv6 addresses (link-local
#        fe80::, ULA, etc.) are out of scope for every caller -
#        they compare against IPv4 host vNIC values.
#
#   Pure function. No Hyper-V calls inside - caller supplies the
#   adapter sequence, so the helper is a pure transform over plain
#   PSCustomObjects.
# ---------------------------------------------------------------------------

# IPv4 dotted-quad regex anchored at both ends so substring matches
# (e.g. "192.168.1.10/24") do not slip through. Defined at script
# scope so any future helper that wants the same shape uses the
# exact same matcher.
$script:Ipv4DottedQuadPattern = '^\d+\.\d+\.\d+\.\d+$'

function Get-VmAdapterIPv4 {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        # Sequence of VMNetworkAdapter (or PSCustomObject) values.
        # Accepts $null / empty - returns @() in that case so
        # callers do not need an explicit nullity check.
        [Parameter(ValueFromPipeline)]
        [object[]] $Adapter
    )

    begin   { $collected = @() }
    process {
        if ($null -ne $Adapter) { $collected += $Adapter }
    }
    end {
        @($collected |
            Where-Object { $_ -and $_.PSObject.Properties['IPAddresses'] } |
            ForEach-Object { $_.IPAddresses } |
            Where-Object { $_ -match $script:Ipv4DottedQuadPattern })
    }
}
