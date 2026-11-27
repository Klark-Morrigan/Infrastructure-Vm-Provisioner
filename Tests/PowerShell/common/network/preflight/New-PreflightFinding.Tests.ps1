BeforeAll {

    $preflight = "$PSScriptRoot\..\..\..\..\..\hyper-v\ubuntu\PowerShell\common\network\preflight"
    . "$preflight\New-PreflightFinding.ps1"
}

Describe 'New-PreflightFinding' {

    It 'returns the status, label and detail it is given' {

        # Act
        $finding = New-PreflightFinding `
            -Status FAIL `
            -Label 'Host vNIC has IPv4' `
            -Detail 'No IPv4 bound.'

        # Assert
        $finding.Status | Should -Be 'FAIL'
        $finding.Label | Should -Be 'Host vNIC has IPv4'
        $finding.Detail | Should -Be 'No IPv4 bound.'
    }

    It 'carries exactly the three properties the report reads' {

        # Act
        $finding = New-PreflightFinding `
            -Status PASS `
            -Label 'Switch exists' `
            -Detail 'SwitchType=Internal'

        # Assert
        $finding.PSObject.Properties.Name | Should -Be @('Status', 'Label', 'Detail')
    }

    It 'leaves the detail empty when none is given' {

        # Act
        $finding = New-PreflightFinding `
            -Status WARN `
            -Label 'Switch type unusual'

        # Assert
        $finding.Detail | Should -Be ''
    }

    # A misspelt status would print in no colour and never count as a FAIL, so
    # it is refused where the finding is made.
    It 'refuses a status outside PASS, WARN and FAIL' {

        # Act
        $creation = {
            New-PreflightFinding `
                -Status 'ERROR' `
                -Label 'Switch exists'
        }

        # Assert
        $creation | Should -Throw -ExpectedMessage '*ERROR*'
    }
}
