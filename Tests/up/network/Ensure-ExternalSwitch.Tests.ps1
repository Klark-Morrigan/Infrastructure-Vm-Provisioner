BeforeAll {
    # Stub Hyper-V / networking cmdlets unavailable outside a Hyper-V host
    # so the source file can be dot-sourced and the cmdlets can be mocked.
    function Get-VMSwitch   { param([string]$Name, $ErrorAction) }
    function New-VMSwitch   { param([string]$Name, $NetAdapterName, $AllowManagementOS) }
    function Get-NetAdapter { param([string]$Name, $ErrorAction) }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\network\Ensure-ExternalSwitch.ps1"

    function New-TestAdapter {
        [PSCustomObject]@{ Name = 'Ethernet'; Status = 'Up' }
    }
}

Describe 'Ensure-ExternalSwitch' {

    # ------------------------------------------------------------------
    Context 'switch absent' {
    # ------------------------------------------------------------------

        It 'creates an External switch bound to the named adapter when none exists' {
            Mock Get-VMSwitch   { }
            Mock Get-NetAdapter { New-TestAdapter }
            Mock New-VMSwitch   { }

            Ensure-ExternalSwitch -Name 'ExtSwitch' -NetAdapterName 'Ethernet'

            Should -Invoke New-VMSwitch -Times 1 -Exactly -ParameterFilter {
                $Name              -eq 'ExtSwitch' -and
                $NetAdapterName    -eq 'Ethernet'  -and
                $AllowManagementOS -eq $true
            }
        }

        It 'verifies the adapter exists before calling New-VMSwitch' {
            # If the adapter is missing the operator gets a Get-NetAdapter
            # hint, not the generic "could not create switch".
            Mock Get-VMSwitch   { }
            Mock Get-NetAdapter { }
            Mock New-VMSwitch   { }

            { Ensure-ExternalSwitch -Name 'ExtSwitch' -NetAdapterName 'Ethernet' } |
                Should -Throw -ExpectedMessage "*Get-NetAdapter*"

            Should -Invoke New-VMSwitch -Times 0
        }

        It 'includes the missing adapter name in the error message' {
            Mock Get-VMSwitch   { }
            Mock Get-NetAdapter { }

            { Ensure-ExternalSwitch -Name 'ExtSwitch' -NetAdapterName 'WiFi-Custom' } |
                Should -Throw -ExpectedMessage "*WiFi-Custom*"
        }
    }

    # ------------------------------------------------------------------
    Context 'switch already present with matching type' {
    # ------------------------------------------------------------------

        It 'reuses an existing External switch without recreating it' {
            Mock Get-VMSwitch   { [PSCustomObject]@{ SwitchType = 'External' } }
            Mock Get-NetAdapter { New-TestAdapter }
            Mock New-VMSwitch   { }

            Ensure-ExternalSwitch -Name 'ExtSwitch' -NetAdapterName 'Ethernet'

            Should -Invoke New-VMSwitch -Times 0
        }

        It 'does not consult the adapter when the switch already exists' {
            # The existing switch has its own binding chosen by whoever
            # created it; we do not second-guess it.
            Mock Get-VMSwitch   { [PSCustomObject]@{ SwitchType = 'External' } }
            Mock Get-NetAdapter { }
            Mock New-VMSwitch   { }

            { Ensure-ExternalSwitch -Name 'ExtSwitch' -NetAdapterName 'AnythingReally' } |
                Should -Not -Throw

            Should -Invoke Get-NetAdapter -Times 0
        }
    }

    # ------------------------------------------------------------------
    Context 'switch present with wrong type' {
    # ------------------------------------------------------------------
        # Silently reusing the wrong-type switch would silently change
        # traffic semantics (no upstream egress) and the operator needs
        # to resolve the collision.

        It 'throws when the existing switch is Internal' {
            Mock Get-VMSwitch { [PSCustomObject]@{ SwitchType = 'Internal' } }
            Mock New-VMSwitch { }

            { Ensure-ExternalSwitch -Name 'ExtSwitch' -NetAdapterName 'Ethernet' } |
                Should -Throw -ExpectedMessage "*Internal*"

            Should -Invoke New-VMSwitch -Times 0
        }

        It 'throws when the existing switch is Private' {
            Mock Get-VMSwitch { [PSCustomObject]@{ SwitchType = 'Private' } }
            Mock New-VMSwitch { }

            { Ensure-ExternalSwitch -Name 'ExtSwitch' -NetAdapterName 'Ethernet' } |
                Should -Throw -ExpectedMessage "*Private*"

            Should -Invoke New-VMSwitch -Times 0
        }

        It 'includes the requested switch name in the error message' {
            Mock Get-VMSwitch { [PSCustomObject]@{ SwitchType = 'Internal' } }

            { Ensure-ExternalSwitch -Name 'ExtSwitch-prod' -NetAdapterName 'Ethernet' } |
                Should -Throw -ExpectedMessage "*ExtSwitch-prod*"
        }
    }
}
