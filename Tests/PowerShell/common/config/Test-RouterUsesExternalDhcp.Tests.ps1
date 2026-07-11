BeforeAll {
    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\common\config\Test-RouterUsesExternalDhcp.ps1"
}

Describe 'Test-RouterUsesExternalDhcp' {

    It 'defaults to static ($false) when externalDhcp is absent' {
        $vm = [PSCustomObject]@{ vmName = 'router-prod' }
        Test-RouterUsesExternalDhcp -Vm $vm | Should -BeFalse
    }

    It 'returns $false when externalDhcp is explicitly false' {
        $vm = [PSCustomObject]@{ vmName = 'router-prod'; externalDhcp = $false }
        Test-RouterUsesExternalDhcp -Vm $vm | Should -BeFalse
    }

    It 'returns $true when externalDhcp is explicitly true' {
        $vm = [PSCustomObject]@{ vmName = 'router-prod'; externalDhcp = $true }
        Test-RouterUsesExternalDhcp -Vm $vm | Should -BeTrue
    }

    It 'treats a quoted "false" string as $true (does NOT rescue it - footgun)' {
        # [bool] of any non-empty string is $true in PowerShell, so a
        # quoted "false" is NOT coerced to static mode. The schema
        # expects a real JSON boolean; this locks the actual behavior so
        # the misleading "defensive cast" reading cannot creep back in.
        $vm = [PSCustomObject]@{ vmName = 'router-prod'; externalDhcp = 'false' }
        Test-RouterUsesExternalDhcp -Vm $vm | Should -BeTrue
    }
}
