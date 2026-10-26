BeforeAll {
    $checks = "$PSScriptRoot\..\..\..\..\..\..\hyper-v\ubuntu\PowerShell\common\network\preflight\checks"
    . "$checks\Test-VmSwitchPresent.ps1"
}

Describe 'Test-VmSwitchPresent' {

    Context 'switch is present' {

        It 'passes and reports the switch type' {
            $finding = Test-VmSwitchPresent -SwitchName 'Sw' `
                -Switch ([PSCustomObject]@{ Name = 'Sw'; SwitchType = 'Internal' })

            $finding.Status | Should -Be 'PASS'
            $finding.Label  | Should -BeLike "*'Sw' exists*"
            $finding.Detail | Should -Be 'SwitchType=Internal'
        }
    }

    Context 'switch is missing' {

        It 'fails with the recreate command for the name that was asked for' {
            $finding = Test-VmSwitchPresent -SwitchName 'NoSuchSwitch' -Switch $null

            $finding.Status | Should -Be 'FAIL'
            $finding.Detail | Should -BeLike "*New-VMSwitch -Name 'NoSuchSwitch' -SwitchType Internal*"
        }

        It 'names the torn-down-by-update cause, not just the absence' {
            # A switch that vanished is almost never a first-run problem: it is
            # a Hyper-V service restart or a Windows update, and an operator
            # who does not know that goes looking in the wrong place.
            $finding = Test-VmSwitchPresent -SwitchName 'Sw' -Switch $null

            $finding.Detail | Should -BeLike '*Windows update*'
        }
    }

    It 'labels PASS and FAIL identically so the two read as one check' {
        $present = Test-VmSwitchPresent -SwitchName 'Sw' `
            -Switch ([PSCustomObject]@{ SwitchType = 'External' })
        $absent  = Test-VmSwitchPresent -SwitchName 'Sw' -Switch $null

        $present.Label | Should -Be $absent.Label
    }
}
