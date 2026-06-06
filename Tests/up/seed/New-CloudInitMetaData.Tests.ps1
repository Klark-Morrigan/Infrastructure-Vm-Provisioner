BeforeAll {
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\seed\New-CloudInitMetaData.ps1"
}

Describe 'New-CloudInitMetaData' {

    It 'sets instance-id to the supplied VmName' {
        (New-CloudInitMetaData -VmName 'node-01') |
            Should -Match '(?m)^instance-id: node-01\s*$'
    }

    It 'sets local-hostname to the supplied VmName' {
        (New-CloudInitMetaData -VmName 'node-01') |
            Should -Match '(?m)^local-hostname: node-01\s*$'
    }

    It 'returns exactly the two expected keys' {
        $lines = (New-CloudInitMetaData -VmName 'node-01') -split "`r?`n" |
            Where-Object { $_.Trim() }
        $lines | Should -HaveCount 2
        $lines[0] | Should -Be 'instance-id: node-01'
        $lines[1] | Should -Be 'local-hostname: node-01'
    }

    It 'rejects an empty VmName' {
        { New-CloudInitMetaData -VmName '' } | Should -Throw
    }
}
