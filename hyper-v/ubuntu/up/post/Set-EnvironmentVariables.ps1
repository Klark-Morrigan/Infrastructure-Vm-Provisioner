<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1.
    Invoked by Invoke-VmPostProvisioning, which owns the SSH lifecycle.
    This function is a step within that lifecycle, not an entry point.
#>

# ---------------------------------------------------------------------------
# Set-EnvironmentVariables
#   Thin per-VM wrapper around the Infrastructure.HyperV transport
#   Set-VmEnvironmentVariables. The transport reconciles a sentinel-
#   delimited managed block inside /etc/environment with the desired
#   entries; lines outside the block are preserved byte-for-byte and an
#   empty entries array is a valid "remove the block" intent.
#
#   Self-contained: takes its own SSH client from the orchestrator. No
#   $Server parameter - writing /etc/environment stages nothing host-
#   side, so passing the file server would only mislead a future reader.
#
#   No defaulting or transformation of inputs: ConvertFrom-VmConfigJson
#   has already run Assert-VmEnvVarsField, so blockName / entries shape
#   is trusted here. The transport itself owns the skip-unchanged
#   optimisation; re-running with an identical block is cheap.
# ---------------------------------------------------------------------------

function Set-EnvironmentVariables {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [object] $Vm
    )

    $blockName = $Vm.envVars.blockName
    $entries   = ConvertTo-Array $Vm.envVars.entries

    Write-Host ("  [envVars] block '$blockName' " +
                "($($entries.Count) entries) -> /etc/environment")

    try {
        Set-VmEnvironmentVariables -SshClient $SshClient `
                                   -Entries   $entries `
                                   -BlockName $blockName
    }
    catch {
        # Surface the VM name so a multi-VM run pinpoints the failure
        # without the operator having to correlate logs by line number.
        throw ("Set-EnvironmentVariables failed on $($Vm.vmName): " +
            "$($_.Exception.Message)")
    }

    Write-Host "  [envVars] [OK] block '$blockName' applied." `
        -ForegroundColor Green
}
