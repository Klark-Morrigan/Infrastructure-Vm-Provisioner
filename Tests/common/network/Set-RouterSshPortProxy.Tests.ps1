BeforeAll {
    # Stub netsh so the source can be dot-sourced and the call
    # sites mocked per-test. The function returns whatever the
    # test wires up via Mock; $LASTEXITCODE is set explicitly
    # because PowerShell does not propagate it across function
    # boundaries when the body does not invoke a native process.
    function global:netsh {
        $script:_NetshCalls += @{ Args = $args }
        $output = $global:_NetshOutput
        $global:LASTEXITCODE = $global:_NetshExitCode
        return $output
    }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\common\network\Get-NetshPortProxyRules.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\common\network\Set-RouterSshPortProxy.ps1"

    function Initialize-NetshState {
        $script:_NetshCalls    = @()
        $global:_NetshOutput   = @()
        $global:_NetshExitCode = 0
    }

    function New-NetshShowOutput {
        # Mimic `netsh interface portproxy show v4tov4` text shape.
        param([object[]] $Rules)
        $lines = @(
            'Listen on ipv4:             Connect to ipv4:',
            '',
            'Address         Port        Address         Port',
            '--------------- ----------  --------------- ----------'
        )
        foreach ($r in $Rules) {
            $lines += ("{0,-15} {1,-11} {2,-15} {3}" -f `
                $r.ListenAddress, $r.ListenPort,
                $r.ConnectAddress, $r.ConnectPort)
        }
        $lines
    }
}

Describe 'Set-RouterSshPortProxy' {

    BeforeEach { Initialize-NetshState }

    Context 'idempotency' {

        It 'skips the add when a matching rule is already present' {
            $global:_NetshOutput = New-NetshShowOutput @(
                [PSCustomObject]@{
                    ListenAddress  = '127.0.0.1'
                    ListenPort     = 2222
                    ConnectAddress = '192.168.137.10'
                    ConnectPort    = 22
                }
            )

            Set-RouterSshPortProxy -ConnectAddress '192.168.137.10'

            # Only the show command should have fired - no add, no delete.
            # @(...) wraps the (possibly $null) Where-Object result so
            # .Count is StrictMode-safe.
            @($script:_NetshCalls | Where-Object { $_.Args -contains 'add' }).Count    |
                Should -Be 0
            @($script:_NetshCalls | Where-Object { $_.Args -contains 'delete' }).Count |
                Should -Be 0
        }
    }

    Context 'when listen target points at a different connect target' {

        It 'deletes the stale rule and adds the new one' {
            $global:_NetshOutput = New-NetshShowOutput @(
                [PSCustomObject]@{
                    ListenAddress  = '127.0.0.1'
                    ListenPort     = 2222
                    ConnectAddress = '10.0.0.99'      # stale
                    ConnectPort    = 22
                }
            )

            Set-RouterSshPortProxy -ConnectAddress '192.168.137.10'

            @($script:_NetshCalls | Where-Object { $_.Args -contains 'delete' }).Count |
                Should -Be 1
            @($script:_NetshCalls | Where-Object { $_.Args -contains 'add' }).Count    |
                Should -Be 1
        }
    }

    Context 'when no rule exists for the listen target' {

        It 'adds a fresh rule' {
            $global:_NetshOutput = New-NetshShowOutput @()

            Set-RouterSshPortProxy -ConnectAddress '192.168.137.10'

            @($script:_NetshCalls | Where-Object { $_.Args -contains 'add' }).Count |
                Should -Be 1
        }

        It 'passes the operator-supplied listen + connect addresses through verbatim' {
            $global:_NetshOutput = New-NetshShowOutput @()

            Set-RouterSshPortProxy `
                -ListenAddress  '127.0.0.1' `
                -ListenPort     8222 `
                -ConnectAddress '192.168.137.42' `
                -ConnectPort    2200

            $addCall = $script:_NetshCalls | Where-Object { $_.Args -contains 'add' }
            $addCall.Args | Should -Contain 'listenaddress=127.0.0.1'
            $addCall.Args | Should -Contain 'listenport=8222'
            $addCall.Args | Should -Contain 'connectaddress=192.168.137.42'
            $addCall.Args | Should -Contain 'connectport=2200'
        }

        It 'throws when netsh add exits non-zero' {
            # First call (show) returns empty/0; subsequent calls
            # need a non-zero exit to test the add failure path.
            $global:_NetshOutput   = @()
            $script:_AddCallCount  = 0
            function global:netsh {
                $script:_NetshCalls += @{ Args = $args }
                $script:_AddCallCount++
                if ($script:_AddCallCount -ge 2) {
                    # The add (second call) fails.
                    $global:LASTEXITCODE = 1
                } else {
                    $global:LASTEXITCODE = 0
                }
                return @()
            }

            { Set-RouterSshPortProxy -ConnectAddress '192.168.137.10' } |
                Should -Throw -ExpectedMessage '*netsh interface portproxy add failed*'
        }
    }
}
