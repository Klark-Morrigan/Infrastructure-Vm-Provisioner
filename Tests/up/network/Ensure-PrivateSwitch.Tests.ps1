BeforeAll {
    # Stub Hyper-V cmdlets unavailable outside a Hyper-V host so the
    # source file can be dot-sourced and the cmdlets can be mocked.
    function Get-VMSwitch { param([string]$Name, $ErrorAction) }
    function New-VMSwitch { param([string]$Name, $SwitchType)  }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\network\Ensure-PrivateSwitch.ps1"
}

Describe 'Ensure-PrivateSwitch' {

    # ------------------------------------------------------------------
    Context 'switch absent' {
    # ------------------------------------------------------------------

        It 'creates a Private switch when none exists' {
            Mock Get-VMSwitch { }
            Mock New-VMSwitch { }

            Ensure-PrivateSwitch -Name 'PrivSwitch-prod'

            Should -Invoke New-VMSwitch -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'PrivSwitch-prod' -and $SwitchType -eq 'Private'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'switch already present with matching type' {
    # ------------------------------------------------------------------

        It 'reuses an existing Private switch without recreating it' {
            Mock Get-VMSwitch { [PSCustomObject]@{ SwitchType = 'Private' } }
            Mock New-VMSwitch { }

            Ensure-PrivateSwitch -Name 'PrivSwitch-prod'

            Should -Invoke New-VMSwitch -Times 0
        }
    }

    # ------------------------------------------------------------------
    Context 'switch present with wrong type' {
    # ------------------------------------------------------------------
        # Silently reusing the wrong-type switch would change traffic
        # semantics: an Internal switch in particular re-exposes a host
        # vNIC that the router-VM design specifically removes.

        It 'throws when the existing switch is Internal' {
            Mock Get-VMSwitch { [PSCustomObject]@{ SwitchType = 'Internal' } }
            Mock New-VMSwitch { }

            { Ensure-PrivateSwitch -Name 'PrivSwitch-prod' } |
                Should -Throw -ExpectedMessage "*Internal*"

            Should -Invoke New-VMSwitch -Times 0
        }

        It 'throws when the existing switch is External' {
            Mock Get-VMSwitch { [PSCustomObject]@{ SwitchType = 'External' } }
            Mock New-VMSwitch { }

            { Ensure-PrivateSwitch -Name 'PrivSwitch-prod' } |
                Should -Throw -ExpectedMessage "*External*"

            Should -Invoke New-VMSwitch -Times 0
        }

        It 'includes the requested switch name in the error message' {
            Mock Get-VMSwitch { [PSCustomObject]@{ SwitchType = 'Internal' } }

            { Ensure-PrivateSwitch -Name 'PrivSwitch-prod' } |
                Should -Throw -ExpectedMessage "*PrivSwitch-prod*"
        }
    }
}
