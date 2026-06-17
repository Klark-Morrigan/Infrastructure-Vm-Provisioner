BeforeAll {
    # Pester needs the SSH command stub at file scope so per-test
    # Mocks attach. The real Invoke-SshClientCommand comes from
    # Infrastructure.HyperV; this stub is the binding target.
    function Invoke-SshClientCommand { param($SshClient, $Command) }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\post\Wait-CloudInitFinished.ps1"

    function New-StatusResult {
        param([string] $Status)
        [PSCustomObject]@{ ExitStatus = 0; Output = "status: $Status" }
    }
}

Describe 'Wait-CloudInitFinished' {

    It 'returns ExitStatus=0 when cloud-init reports done on the first poll' {
        Mock Invoke-SshClientCommand { New-StatusResult 'done' }

        $result = Wait-CloudInitFinished `
            -SshClient ([PSCustomObject]@{}) `
            -VmName 'router-e2e'

        $result.ExitStatus | Should -Be 0
        $result.Output     | Should -Be 'done'
    }

    It 'returns ExitStatus=0 when cloud-init reports disabled' {
        Mock Invoke-SshClientCommand { New-StatusResult 'disabled' }

        $result = Wait-CloudInitFinished `
            -SshClient ([PSCustomObject]@{}) `
            -VmName 'router-e2e'

        $result.ExitStatus | Should -Be 0
    }

    It 'returns ExitStatus=1 when cloud-init reports error' {
        Mock Invoke-SshClientCommand { New-StatusResult 'error' }

        $result = Wait-CloudInitFinished `
            -SshClient ([PSCustomObject]@{}) `
            -VmName 'router-e2e'

        $result.ExitStatus | Should -Be 1
        $result.Output     | Should -Be 'error'
    }

    It 'polls until the status transitions to done' {
        # First two polls report running, third reports done. The
        # loop must keep going until the terminal state shows up.
        $script:_callCount = 0
        Mock Invoke-SshClientCommand {
            $script:_callCount++
            if ($script:_callCount -lt 3) {
                return New-StatusResult 'running'
            }
            return New-StatusResult 'done'
        }
        # Drop the poll interval to zero so the test does not sleep.
        $result = Wait-CloudInitFinished `
            -SshClient ([PSCustomObject]@{}) `
            -VmName 'router-e2e' `
            -PollIntervalSeconds 0

        $script:_callCount | Should -Be 3
        $result.ExitStatus | Should -Be 0
        $result.Output     | Should -Be 'done'
    }

    It 'queries `cloud-init status` (no --wait flag) every poll' {
        # The pre-change shape was `timeout NN cloud-init status --wait`
        # which blocked the SSH session for minutes with no output.
        # The poll loop must NEVER send --wait, otherwise it loses
        # the heartbeat and the operator sees a silent hang.
        $script:_observedCommands = @()
        Mock Invoke-SshClientCommand {
            param($SshClient, $Command)
            $script:_observedCommands += $Command
            New-StatusResult 'done'
        }

        Wait-CloudInitFinished `
            -SshClient ([PSCustomObject]@{}) `
            -VmName 'router-e2e' | Out-Null

        $script:_observedCommands       | Should -Contain 'cloud-init status 2>&1'
        $script:_observedCommands | ForEach-Object { $_ | Should -Not -Match '--wait' }
    }

    It 'returns ExitStatus=124 (timeout) when the budget is exhausted before terminal' {
        # 0-second budget + non-terminal status forces immediate
        # timeout. Mirrors GNU timeout's exit code so existing
        # non-zero branches keep working.
        Mock Invoke-SshClientCommand { New-StatusResult 'running' }

        $result = Wait-CloudInitFinished `
            -SshClient ([PSCustomObject]@{}) `
            -VmName 'router-e2e' `
            -BudgetSeconds 0 `
            -PollIntervalSeconds 0

        $result.ExitStatus | Should -Be 124
    }

    It 'parses an unknown status string as "unknown"' {
        # If cloud-init prints nothing matching `status:` (a parsing
        # quirk, or an early boot stage), the helper should not
        # crash - it should fall through to the budget timeout
        # rather than treating an unparseable line as terminal.
        Mock Invoke-SshClientCommand {
            [PSCustomObject]@{ ExitStatus = 0; Output = 'mystery output' }
        }

        $result = Wait-CloudInitFinished `
            -SshClient ([PSCustomObject]@{}) `
            -VmName 'router-e2e' `
            -BudgetSeconds 0 `
            -PollIntervalSeconds 0

        $result.ExitStatus | Should -Be 124
        $result.Output     | Should -Be 'unknown'
    }
}
