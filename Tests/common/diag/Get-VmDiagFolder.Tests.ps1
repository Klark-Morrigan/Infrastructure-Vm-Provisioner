BeforeAll {
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\common\diag\Get-VmDiagFolder.ps1"
}

Describe 'Get-VmDiagFolder' {

    It 'joins VmConfigPath, "diagnostics", VmName, Timestamp in order' {
        $result = Get-VmDiagFolder -VmConfigPath 'E:\a_VMs\Hyper-V\Config' `
                                   -VmName       'router-e2e' `
                                   -Timestamp    '2026-06-10_16-00-00'

        $result | Should -Be (
            'E:\a_VMs\Hyper-V\Config\diagnostics\router-e2e\2026-06-10_16-00-00'
        )
    }

    It 'returns a [string]' {
        $result = Get-VmDiagFolder -VmConfigPath 'X' -VmName 'Y' -Timestamp 'Z'
        $result | Should -BeOfType [string]
    }

    It 'does not create the directory on disk' {
        # Pure path constructor. Callers that need the folder to exist
        # invoke New-Item themselves; the helper must not have that
        # side effect (would surprise consumers and make tests slower).
        $base = Join-Path 'TestDrive:\' ([Guid]::NewGuid().Guid)
        New-Item -ItemType Directory -Path $base | Out-Null

        $result = Get-VmDiagFolder -VmConfigPath $base `
                                   -VmName       'router-e2e' `
                                   -Timestamp    '2026-06-10_16-00-00'

        Test-Path -Path $result -PathType Container | Should -BeFalse
    }

    It 'throws on empty VmConfigPath' {
        { Get-VmDiagFolder -VmConfigPath '' `
                           -VmName       'router-e2e' `
                           -Timestamp    '2026-06-10_16-00-00' } |
            Should -Throw
    }

    It 'throws on empty VmName' {
        { Get-VmDiagFolder -VmConfigPath 'X' `
                           -VmName       '' `
                           -Timestamp    '2026-06-10_16-00-00' } |
            Should -Throw
    }

    It 'throws on empty Timestamp' {
        { Get-VmDiagFolder -VmConfigPath 'X' `
                           -VmName       'router-e2e' `
                           -Timestamp    '' } |
            Should -Throw
    }
}
