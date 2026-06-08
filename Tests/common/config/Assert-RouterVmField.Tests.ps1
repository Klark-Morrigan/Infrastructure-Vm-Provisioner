BeforeAll {
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\common\config\Assert-RouterVmField.ps1"

    # Builds a router VM definition with every router-specific field
    # populated. Individual tests override or strip fields to exercise
    # specific rules.
    function New-RouterVm {
        [PSCustomObject]@{
            vmName               = 'router-prod'
            externalSwitchName   = 'ExternalSwitch-Shared'
            externalAdapterName  = 'Ethernet'
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
    Context 'externalDhcp (default true, opt-out for static)' {
    # ------------------------------------------------------------------
        # externalDhcp defaults to true so a router VM works on whatever
        # LAN the host's External vSwitch is currently bridged to. The
        # default omits ipAddress / subnetMask / gateway from the schema.
        # An operator who wants a pinned static can set externalDhcp:
        # false; the three fields then become required.

        It 'accepts a router VM with no ipAddress when externalDhcp is absent (default true)' {
            { Assert-RouterVmField -Vm (New-RouterVm) } | Should -Not -Throw
        }

        It 'accepts a router VM with externalDhcp=true explicitly' {
            $vm = New-RouterVm
            $vm | Add-Member -MemberType NoteProperty -Name externalDhcp -Value $true
            { Assert-RouterVmField -Vm $vm } | Should -Not -Throw
        }

        It 'accepts a router VM with externalDhcp=false and all three static fields' {
            $vm = New-RouterVm
            $vm | Add-Member -MemberType NoteProperty -Name externalDhcp -Value $false
            $vm | Add-Member -MemberType NoteProperty -Name ipAddress    -Value '192.168.1.10'
            $vm | Add-Member -MemberType NoteProperty -Name subnetMask   -Value '24'
            $vm | Add-Member -MemberType NoteProperty -Name gateway      -Value '192.168.1.1'
            { Assert-RouterVmField -Vm $vm } | Should -Not -Throw
        }

        It 'throws when externalDhcp is false and ipAddress is missing' {
            $vm = New-RouterVm
            $vm | Add-Member -MemberType NoteProperty -Name externalDhcp -Value $false
            $vm | Add-Member -MemberType NoteProperty -Name subnetMask   -Value '24'
            $vm | Add-Member -MemberType NoteProperty -Name gateway      -Value '192.168.1.1'
            { Assert-RouterVmField -Vm $vm } |
                Should -Throw -ExpectedMessage "*externalDhcp=false*ipAddress*"
        }

        It 'throws when externalDhcp is false and gateway is missing' {
            $vm = New-RouterVm
            $vm | Add-Member -MemberType NoteProperty -Name externalDhcp -Value $false
            $vm | Add-Member -MemberType NoteProperty -Name ipAddress    -Value '192.168.1.10'
            $vm | Add-Member -MemberType NoteProperty -Name subnetMask   -Value '24'
            { Assert-RouterVmField -Vm $vm } |
                Should -Throw -ExpectedMessage "*externalDhcp=false*gateway*"
        }

        It 'throws when externalDhcp is false and a static field is empty' {
            $vm = New-RouterVm
            $vm | Add-Member -MemberType NoteProperty -Name externalDhcp -Value $false
            $vm | Add-Member -MemberType NoteProperty -Name ipAddress    -Value ''
            $vm | Add-Member -MemberType NoteProperty -Name subnetMask   -Value '24'
            $vm | Add-Member -MemberType NoteProperty -Name gateway      -Value '192.168.1.1'
            { Assert-RouterVmField -Vm $vm } |
                Should -Throw -ExpectedMessage "*non-empty*"
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
