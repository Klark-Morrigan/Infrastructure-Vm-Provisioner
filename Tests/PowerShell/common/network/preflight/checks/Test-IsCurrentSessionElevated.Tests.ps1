BeforeAll {
    $checks = "$PSScriptRoot\..\..\..\..\..\..\hyper-v\ubuntu\PowerShell\common\network\preflight\checks"
    . "$checks\Test-IsCurrentSessionElevated.ps1"
}

Describe 'Test-IsCurrentSessionElevated' {

    # The WindowsPrincipal call cannot be mocked, so the assertions are about
    # the CONTRACT the preflight relies on - a plain boolean, no throw - rather
    # than about which answer this particular session gets. The answer itself
    # is cross-checked against the same API below.
    It 'returns a boolean without throwing' {
        $result = Test-IsCurrentSessionElevated

        $result | Should -BeOfType [bool]
    }

    It 'agrees with the Administrator role on the current identity' {
        $expected = [Security.Principal.WindowsPrincipal]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)

        Test-IsCurrentSessionElevated | Should -Be $expected
    }

    It 'returns exactly one value - the preflight branches on it directly' {
        @(Test-IsCurrentSessionElevated).Count | Should -Be 1
    }
}
