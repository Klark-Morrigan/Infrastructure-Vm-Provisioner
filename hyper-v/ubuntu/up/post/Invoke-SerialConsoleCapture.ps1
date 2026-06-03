<#
.NOTES
    TODO(diagnostic, remove): pre-SSH serial-console capture. Paired
    with Invoke-CloudInitDiagnostics.ps1 - that script captures state
    AFTER cloud-init reports done; this one captures the live console
    feed from VM power-on through cloud-init's modules, so we still
    have data when sshd never comes up (cloud-config hangs, kernel
    panic, etc.).

    Outputs land host-side under the same per-VM-per-run subdirectory
    convention:
        <VmConfigPath>\diagnostics\<vmName>\<timestamp>\console.log

    Remove this file, its dot-source line in provision.ps1, and the
    Start/Stop calls in create-vm.ps1 once the pre-SSH unknowns have
    been resolved.

    Do not run this file directly. Dot-sourced by provision.ps1.
#>

# ---------------------------------------------------------------------------
# Start-SerialConsoleCapture
#   Configures the VM's COM1 to a named pipe on the host and starts a
#   background reader that copies everything received from the pipe to a
#   file. Ubuntu's cloud-image GRUB sends kernel + cloud-init output to
#   /dev/ttyS0 (which maps to COM1), so the resulting file is the entire
#   boot transcript.
#
#   Must be called while the VM is in the Off state - Set-VMComPort
#   refuses to modify a running VM. Returns a capture context that
#   Stop-SerialConsoleCapture consumes.
#
#   The reader runs as a Start-Job background job. When the VM stops,
#   Hyper-V closes the pipe and the reader exits naturally. The Stop
#   helper is a belt-and-braces for the case where the orchestrator
#   tears down before the VM does.
# ---------------------------------------------------------------------------

function Start-SerialConsoleCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $VmName,

        [Parameter(Mandatory)]
        [string] $VmConfigPath,

        [Parameter(Mandatory)]
        [string] $Timestamp
    )

    # Per-VM-per-run subdirectory. The caller supplies a single
    # $Timestamp so console.log (this script) and the post-cloud-init
    # dumps (Invoke-CloudInitDiagnostics) from the same provisioning
    # run land under the SAME timestamped folder. Generating a fresh
    # timestamp here would split them across two folders separated by
    # the cloud-init wall-clock (~6 minutes), which made matching
    # console + diag outputs visually confusing.
    $diagDir   = Join-Path $VmConfigPath 'diagnostics'
    $diagDir   = Join-Path $diagDir      $VmName
    $diagDir   = Join-Path $diagDir      $timestamp
    if (-not (Test-Path -Path $diagDir -PathType Container)) {
        New-Item -ItemType Directory -Path $diagDir -Force | Out-Null
    }

    $consoleLogPath = Join-Path $diagDir 'console.log'
    # Pipe name includes vmName so concurrent VMs do not collide. Hyper-V
    # creates the pipe on the host when the VM starts; the reader Connect
    # call below waits with a generous timeout for that to happen.
    $pipeName       = "$VmName-com1"
    $pipePath       = "\\.\pipe\$pipeName"

    Set-VMComPort -VMName $VmName -Number 1 -Path $pipePath | Out-Null

    Write-Host "  [console] capturing serial console to $consoleLogPath"

    # Background reader. Async file writes via a FileStream + StreamWriter
    # so the loop never blocks the pipe (otherwise Hyper-V's small kernel-
    # side buffer could overflow and drop early boot lines).
    $job = Start-Job -Name "SerialCapture-$VmName" -ScriptBlock {
        param($pipeName, $logPath)

        $client = [System.IO.Pipes.NamedPipeClientStream]::new(
            '.', $pipeName, [System.IO.Pipes.PipeDirection]::In)
        $file   = $null
        $writer = $null
        try {
            # 60s lets Start-VM complete and Hyper-V publish the pipe.
            $client.Connect(60000)

            $file   = [System.IO.FileStream]::new(
                $logPath,
                [System.IO.FileMode]::Create,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::Read)
            $writer = [System.IO.StreamWriter]::new($file)
            $writer.AutoFlush = $true

            $buffer = [byte[]]::new(4096)
            while ($true) {
                $read = $client.Read($buffer, 0, $buffer.Length)
                if ($read -le 0) { break }  # pipe closed (VM stopped)
                $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
                $writer.Write($text)
            }
        } finally {
            if ($null -ne $writer) { $writer.Dispose() }
            if ($null -ne $file)   { $file.Dispose() }
            if ($client.IsConnected) { $client.Close() }
            $client.Dispose()
        }
    } -ArgumentList $pipeName, $consoleLogPath

    [PSCustomObject]@{
        Job            = $job
        ConsoleLogPath = $consoleLogPath
        VmName         = $VmName
    }
}

# ---------------------------------------------------------------------------
# Stop-SerialConsoleCapture
#   Tears down the background reader started by Start-SerialConsoleCapture.
#   Safe to call with $null (no-op) so callers can wire it into a finally
#   block without an outer null guard.
# ---------------------------------------------------------------------------

function Stop-SerialConsoleCapture {
    [CmdletBinding()]
    param(
        [object] $Capture
    )

    if ($null -eq $Capture -or $null -eq $Capture.Job) { return }

    # Stop-Job aborts the read loop if the pipe is still open. Remove-Job
    # frees the runspace. SilentlyContinue because the job may already
    # have exited if Hyper-V closed the pipe (VM stopped).
    Stop-Job   -Job $Capture.Job -ErrorAction SilentlyContinue
    Remove-Job -Job $Capture.Job -Force -ErrorAction SilentlyContinue

    Write-Host "  [console] capture stopped: $($Capture.ConsoleLogPath)"
}
