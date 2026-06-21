BeforeAll {
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\common\config\Test-RouterUsesExternalDhcp.ps1"
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\common\config\Assert-RouterVmField.ps1"

    # Builds a valid STATIC router definition - static is the schema
    # default (externalDhcp absent => $false), so the canonical fixture
    # carries the ext0 ipAddress/gateway the default mode requires.
    # Individual tests override or strip fields to exercise specific rules.
    function New-RouterVm {
        [PSCustomObject]@{
            vmName               = 'router-prod'
            externalSwitchName   = 'ExternalSwitch-Shared'
            externalAdapterName  = 'Ethernet'
            ipAddress            = '192.168.137.10'
            gateway              = '192.168.137.1'
            privateSwitchName    = 'PrivateSwitch-Production'
            privateIpAddress     = '10.10.0.1'
        }
    }
}

Describe 'Assert-RouterVmField' {

    # ------------------------------------------------------------------
    Context 'required router fields' {
    # ------------------------------------------------------------------

        It 'returns silently when all router-specific fields are present' {
            { Assert-RouterVmField -Vm (New-RouterVm) } | Should -Not -Throw
        }

        It 'throws when externalSwitchName is missing' {
            $vm = New-RouterVm
            $vm.PSObject.Properties.Remove('externalSwitchName')
            { Assert-RouterVmField -Vm $vm } |
                Should -Throw -ExpectedMessage "*externalSwitchName*"
        }

        It 'throws when externalAdapterName is missing' {
            $vm = New-RouterVm
            $vm.PSObject.Properties.Remove('externalAdapterName')
            { Assert-RouterVmField -Vm $vm } |
                Should -Throw -ExpectedMessage "*externalAdapterName*"
        }

        It 'throws when privateIpAddress is missing' {
            $vm = New-RouterVm
            $vm.PSObject.Properties.Remove('privateIpAddress')
            { Assert-RouterVmField -Vm $vm } |
                Should -Throw -ExpectedMessage "*privateIpAddress*"
        }

        It 'throws when a required field is present but empty' {
            $vm = New-RouterVm
            $vm.privateIpAddress = ''
            { Assert-RouterVmField -Vm $vm } |
                Should -Throw -ExpectedMessage "*non-empty*"
        }

        It 'throws when a required field is whitespace-only' {
            $vm = New-RouterVm
            $vm.privateIpAddress = '   '
            { Assert-RouterVmField -Vm $vm } |
                Should -Throw -ExpectedMessage "*non-empty*"
        }

        It 'includes the vmName in the error context' {
            $vm = New-RouterVm
            $vm.PSObject.Properties.Remove('privateIpAddress')
            { Assert-RouterVmField -Vm $vm } |
                Should -Throw -ExpectedMessage "*router-prod*"
        }

        It 'falls back to (unknown) when vmName is absent' {
            $vm = New-RouterVm
            $vm.PSObject.Properties.Remove('vmName')
            $vm.PSObject.Properties.Remove('privateIpAddress')
            { Assert-RouterVmField -Vm $vm } |
                Should -Throw -ExpectedMessage "*(unknown)*"
        }
    }

    # ------------------------------------------------------------------
    Context 'externalDhcp (default false / static; DHCP rejected as unfinished)' {
    # ------------------------------------------------------------------
        # externalDhcp defaults to $false (static), matching the only
        # validated host topology (Internal+ICS). The canonical fixture is
        # therefore a complete static router accepted with no externalDhcp
        # field. externalDhcp=true (DHCP) is unfinished/unsupported, so the
        # validator rejects it outright.

        It 'accepts a static router by default (externalDhcp absent)' {
            { Assert-RouterVmField -Vm (New-RouterVm) } | Should -Not -Throw
        }

        It 'accepts a static router with externalDhcp=false explicit' {
            $vm = New-RouterVm
            $vm | Add-Member -MemberType NoteProperty -Name externalDhcp -Value $false
            { Assert-RouterVmField -Vm $vm } | Should -Not -Throw
        }

        It 'rejects a DHCP router (externalDhcp=true) as unfinished/unsupported' {
            # The gate fires regardless of whether static fields are present.
            $vm = New-RouterVm
            $vm | Add-Member -MemberType NoteProperty -Name externalDhcp -Value $true
            { Assert-RouterVmField -Vm $vm } |
                Should -Throw -ExpectedMessage "*DHCP mode is unfinished and unsupported*"
        }

        It 'throws when static (the default) and ipAddress is missing' {
            $vm = New-RouterVm
            $vm.PSObject.Properties.Remove('ipAddress')
            { Assert-RouterVmField -Vm $vm } |
                Should -Throw -ExpectedMessage "*externalDhcp=false*ipAddress*"
        }

        It 'throws when static (the default) and gateway is missing' {
            $vm = New-RouterVm
            $vm.PSObject.Properties.Remove('gateway')
            { Assert-RouterVmField -Vm $vm } |
                Should -Throw -ExpectedMessage "*externalDhcp=false*gateway*"
        }

        It 'throws when static and a static field is empty' {
            $vm = New-RouterVm
            $vm.ipAddress = ''
            { Assert-RouterVmField -Vm $vm } |
                Should -Throw -ExpectedMessage "*non-empty*"
        }

        # externalDhcp must be a real JSON boolean. A quoted string or a
        # number would otherwise slip through the [bool] cast in
        # Test-RouterUsesExternalDhcp ([bool] of any non-empty string is
        # $true), silently flipping a static-mode intent to DHCP.

        It 'throws when externalDhcp is a quoted string ("false")' {
            $vm = New-RouterVm
            $vm | Add-Member -MemberType NoteProperty -Name externalDhcp -Value 'false'
            { Assert-RouterVmField -Vm $vm } |
                Should -Throw -ExpectedMessage "*externalDhcp must be a JSON boolean*"
        }

        It 'throws when externalDhcp is a JSON number' {
            $vm = New-RouterVm
            $vm | Add-Member -MemberType NoteProperty -Name externalDhcp -Value 0
            { Assert-RouterVmField -Vm $vm } |
                Should -Throw -ExpectedMessage "*externalDhcp must be a JSON boolean*"
        }

        It 'throws when externalDhcp is null' {
            $vm = New-RouterVm
            $vm | Add-Member -MemberType NoteProperty -Name externalDhcp -Value $null
            { Assert-RouterVmField -Vm $vm } |
                Should -Throw -ExpectedMessage "*externalDhcp must be a JSON boolean*not null*"
        }
    }

    # ------------------------------------------------------------------
    Context 'rejected toolchain blocks' {
    # ------------------------------------------------------------------
        # Router VMs are intentionally minimal (nftables + dnsmasq only).
        # Surfacing a toolchain entry at schema-time stops it from
        # silently reaching the reconciler and installing a JDK on the
        # gateway.

        It 'throws when javaDevKit is present' {
            $vm = New-RouterVm
            $vm | Add-Member -MemberType NoteProperty -Name javaDevKit `
                  -Value ([PSCustomObject]@{ vendor = 'temurin'; version = '21' })
            { Assert-RouterVmField -Vm $vm } |
                Should -Throw -ExpectedMessage "*javaDevKit*"
        }

        It 'throws when dotnetSdk is present' {
            $vm = New-RouterVm
            $vm | Add-Member -MemberType NoteProperty -Name dotnetSdk `
                  -Value ([PSCustomObject]@{ channel = '10.0'; version = '10.0.100' })
            { Assert-RouterVmField -Vm $vm } |
                Should -Throw -ExpectedMessage "*dotnetSdk*"
        }

        It 'throws when dotnetTools is present' {
            $vm = New-RouterVm
            $vm | Add-Member -MemberType NoteProperty -Name dotnetTools `
                  -Value @(([PSCustomObject]@{ id = 'dotnet-ef'; version = '8.0.0' }))
            { Assert-RouterVmField -Vm $vm } |
                Should -Throw -ExpectedMessage "*dotnetTools*"
        }
    }
}
