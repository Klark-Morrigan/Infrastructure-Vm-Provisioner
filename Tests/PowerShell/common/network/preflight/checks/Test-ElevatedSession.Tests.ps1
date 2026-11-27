BeforeAll {

    $preflight = "$PSScriptRoot\..\..\..\..\..\..\hyper-v\ubuntu\PowerShell\common\network\preflight"

    . "$preflight\New-PreflightFinding.ps1"
    . "$preflight\checks\Test-IsCurrentSessionElevated.ps1"
    . "$preflight\checks\Test-ElevatedSession.ps1"
}

Describe 'Test-ElevatedSession' {

    It 'passes when the session is elevated' {

        # Arrange
        Mock Test-IsCurrentSessionElevated { $true }

        # Act
        $finding = Test-ElevatedSession

        # Assert
        $finding.Status | Should -Be 'PASS'
        $finding.Label | Should -Be 'PowerShell session is elevated'
        $finding.Detail | Should -Be 'Hyper-V cmdlets are reachable.'
    }

    It 'fails with the way to fix it when the session is not elevated' {

        # Arrange
        Mock Test-IsCurrentSessionElevated { $false }

        $expectedDetail =
            "Hyper-V and Get-Net* cmdlets need admin (or Hyper-V Administrators group). " +
            "Re-run from an elevated PowerShell."

        # Act
        $finding = Test-ElevatedSession

        # Assert
        $finding.Status | Should -Be 'FAIL'
        $finding.Label | Should -Be 'PowerShell session is elevated'
        $finding.Detail | Should -Be $expectedDetail
    }
}
