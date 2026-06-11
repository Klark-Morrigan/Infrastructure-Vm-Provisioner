BeforeAll {
    # Stub netsh at file scope so per-test Mocks can shape the output
    # without invoking the real binary.
    function global:netsh {
        $output = $global:_NetshOutput
        $global:LASTEXITCODE = 0
        return $output
    }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\common\network\Get-NetshPortProxyRules.ps1"

    function New-NetshShowOutput {
        # Mimic the textual shape `netsh interface portproxy show v4tov4`
        # emits, including the locale-stable rule rows.
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

Describe 'Get-NetshPortProxyRules' {

    It 'returns an empty array when no rules are configured' {
        $global:_NetshOutput = New-NetshShowOutput @()

        $result = @(Get-NetshPortProxyRules)

        $result.Count | Should -Be 0
    }

    It 'returns an empty array when netsh produces no output at all' {
        $global:_NetshOutput = $null

        $result = @(Get-NetshPortProxyRules)

        $result.Count | Should -Be 0
    }

    It 'parses a single rule into the expected shape' {
        $global:_NetshOutput = New-NetshShowOutput @(
            [PSCustomObject]@{
                ListenAddress  = '127.0.0.1'
                ListenPort     = 2222
                ConnectAddress = '192.168.137.10'
                ConnectPort    = 22
            }
        )

        $result = @(Get-NetshPortProxyRules)

        $result.Count                | Should -Be 1
        $result[0].ListenAddress     | Should -Be '127.0.0.1'
        $result[0].ListenPort        | Should -Be 2222
        $result[0].ConnectAddress    | Should -Be '192.168.137.10'
        $result[0].ConnectPort       | Should -Be 22
    }

    It 'parses multiple rules' {
        $global:_NetshOutput = New-NetshShowOutput @(
            [PSCustomObject]@{
                ListenAddress  = '127.0.0.1'
                ListenPort     = 2222
                ConnectAddress = '192.168.137.10'
                ConnectPort    = 22
            }
            [PSCustomObject]@{
                ListenAddress  = '127.0.0.1'
                ListenPort     = 2223
                ConnectAddress = '192.168.137.11'
                ConnectPort    = 22
            }
        )

        $result = @(Get-NetshPortProxyRules)

        $result.Count | Should -Be 2
        $result[1].ListenPort | Should -Be 2223
    }

    It 'returns ports as integers (not strings)' {
        # Downstream callers compare ports with -eq <int>; if parsed
        # as string the comparison silently fails under PowerShell's
        # type coercion rules. Explicit type assertion guards against
        # a regression that would re-introduce the silent miss.
        $global:_NetshOutput = New-NetshShowOutput @(
            [PSCustomObject]@{
                ListenAddress  = '127.0.0.1'
                ListenPort     = 2222
                ConnectAddress = '192.168.137.10'
                ConnectPort    = 22
            }
        )

        $result = @(Get-NetshPortProxyRules)

        $result[0].ListenPort  | Should -BeOfType [int]
        $result[0].ConnectPort | Should -BeOfType [int]
    }

    It 'ignores header rows even when the layout shifts' {
        # The regex anchors on "<ipv4> <port> <ipv4> <port>" so
        # cosmetic header changes (e.g. a locale-translated label,
        # an extra blank line) do not produce a phantom rule.
        $global:_NetshOutput = @(
            'Some translated header text here',
            '',
            'Another line',
            'Address         Port        Address         Port',
            '--------------- ----------  --------------- ----------',
            '127.0.0.1       2222        192.168.137.10  22'
        )

        $result = @(Get-NetshPortProxyRules)

        $result.Count | Should -Be 1
        $result[0].ListenPort | Should -Be 2222
    }
}
