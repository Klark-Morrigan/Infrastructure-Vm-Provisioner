<#
.NOTES
    SSH command/output tee. Wraps a real SSH.NET client with a
    PSCustomObject whose RunCommand ScriptMethod appends each command,
    its stdout, stderr, exit status, and elapsed time to a host-side
    log file before returning the result to the caller. The wrapper
    is duck-type-compatible with the real client - Invoke-SshClientCommand
    uses [object] $SshClient and only touches .RunCommand, so providers
    and other consumers see no behavioural difference.

    Used by Invoke-VmPostProvisioning to capture every SSH command run
    during the post-provisioning phase (cloud-init wait, files copy,
    reconcile, env vars) into <diagDir>/ssh.log alongside the other
    diagnostic outputs. The headline value is for the reconcile sub-
    steps, which would otherwise leave no trace on disk beyond a
    one-line Write-Host per provider.

    Do not run this file directly. Dot-sourced by provision.ps1.
#>

# ---------------------------------------------------------------------------
# New-DiagnosticSshClientWrapper
#   Returns a PSCustomObject that forwards RunCommand / IsConnected /
#   Disconnect / Dispose to the wrapped real client, additionally
#   appending a structured record of each command to $LogPath.
#
#   Why a wrapper rather than modifying Invoke-SshClientCommand: the
#   real cmdlet lives in Infrastructure.HyperV and is consumed by every
#   other repo (Vm-Users, GitHubRunners, ...); adding a -LogPath param
#   would mean a public-contract change there. A per-VM wrapper is
#   contained to this diagnostic effort and removes cleanly when we
#   delete this file.
# ---------------------------------------------------------------------------

function New-DiagnosticSshClientWrapper {
    [CmdletBinding()]
    param(
        # The real SSH.NET client returned by New-VmSshClient. Typed
        # [object] for the same reason Invoke-SshClientCommand uses
        # [object] - avoids resolving the Renci type at module-import
        # time.
        [Parameter(Mandatory)]
        [object] $RealClient,

        [Parameter(Mandatory)]
        [string] $VmConfigPath,

        [Parameter(Mandatory)]
        [string] $VmName,

        [Parameter(Mandatory)]
        [string] $Timestamp
    )

    # Per-VM-per-run subdirectory matches the convention used by
    # Invoke-CloudInitDiagnostics and Invoke-SerialConsoleCapture, so
    # ssh.log lands next to console.log and the cloud-init dumps from
    # the same provisioning run.
    $diagDir = Get-VmDiagFolder -VmConfigPath $VmConfigPath `
                                -VmName       $VmName `
                                -Timestamp    $Timestamp
    if (-not (Test-Path -Path $diagDir -PathType Container)) {
        New-Item -ItemType Directory -Path $diagDir -Force | Out-Null
    }
    $logPath = Join-Path $diagDir 'ssh.log'

    $wrapper = [PSCustomObject]@{
        _real    = $RealClient
        _logPath = $logPath
    }

    # IsConnected is read by Invoke-VmPostProvisioning's finally block
    # before deciding whether to Disconnect. Exposing it as a
    # ScriptProperty (not a plain property) so the value is always
    # current at the moment it is read.
    $wrapper | Add-Member -MemberType ScriptProperty -Name 'IsConnected' `
        -Value { $this._real.IsConnected } -Force

    # The main hook: every Invoke-SshClientCommand call funnels here
    # because that cmdlet does `$SshClient.RunCommand($Command)` against
    # whatever object it receives. The wrapper logs around the call and
    # returns the real result object so downstream property access
    # (Result, Error, ExitStatus) continues to work unchanged.
    $wrapper | Add-Member -MemberType ScriptMethod -Name 'RunCommand' -Value {
        param($command)

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $result = $this._real.RunCommand($command)
        $sw.Stop()

        # Compose a record with a clear visual separator so a human
        # eyeballing ssh.log can scan one command per block. Timestamp
        # uses host-local time for correlation with the orchestrator's
        # Write-Host lines; elapsed and exit_status make the slow / failing
        # commands easy to grep for.
        $stamp = (Get-Date).ToString('HH:mm:ss.fff')
        $sep   = '-' * 78
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add($sep)
        $lines.Add(
            "[$stamp] elapsed=$([int]$sw.ElapsedMilliseconds)ms " +
            "exit=$($result.ExitStatus)")
        $lines.Add("$ $command")
        if ($result.Result -and $result.Result.Length -gt 0) {
            $lines.Add('--- stdout ---')
            $lines.Add($result.Result.TrimEnd())
        }
        if ($result.Error -and $result.Error.Length -gt 0) {
            $lines.Add('--- stderr ---')
            $lines.Add($result.Error.TrimEnd())
        }
        Add-Content -Path $this._logPath -Value ($lines -join "`n")

        return $result
    } -Force

    # Forward Disconnect / Dispose so the orchestrator's finally block
    # tears down the real client correctly. The wrapper has no
    # connection state of its own to clean up.
    $wrapper | Add-Member -MemberType ScriptMethod -Name 'Disconnect' `
        -Value { $this._real.Disconnect() } -Force
    $wrapper | Add-Member -MemberType ScriptMethod -Name 'Dispose' `
        -Value { $this._real.Dispose() } -Force

    return $wrapper
}
