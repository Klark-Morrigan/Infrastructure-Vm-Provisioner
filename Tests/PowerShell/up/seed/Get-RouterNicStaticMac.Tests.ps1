BeforeAll {
    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\up\seed\Get-RouterNicStaticMac.ps1"
}

Describe 'Get-RouterNicStaticMac' {

    # ------------------------------------------------------------------
    Context 'output shape' {
    # ------------------------------------------------------------------

        It 'returns a hashtable with HyperV and Netplan keys' {
            $mac = Get-RouterNicStaticMac -VmName 'router-prod' -Role 'external'
            $mac | Should -BeOfType ([hashtable])
            $mac.Keys | Should -Contain 'HyperV'
            $mac.Keys | Should -Contain 'Netplan'
        }

        It 'HyperV format is 12 lowercase hex chars with no separators' {
            $mac = Get-RouterNicStaticMac -VmName 'router-prod' -Role 'external'
            $mac.HyperV | Should -Match '^[0-9a-f]{12}$'
        }

        It 'Netplan format is six lowercase hex octets joined by colons' {
            $mac = Get-RouterNicStaticMac -VmName 'router-prod' -Role 'external'
            $mac.Netplan | Should -Match '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$'
        }

        It 'the two formats encode the same six bytes' {
            $mac = Get-RouterNicStaticMac -VmName 'router-prod' -Role 'external'
            ($mac.Netplan -replace ':', '') | Should -Be $mac.HyperV
        }
    }

    # ------------------------------------------------------------------
    Context 'locally-administered prefix' {
    # ------------------------------------------------------------------
        # 0x02 first byte = locally-administered unicast. The IEEE
        # reserves this range for site-managed MACs - using it avoids
        # any chance of colliding with an assigned OUI.

        It 'starts with 02 (locally administered, unicast)' {
            $mac = Get-RouterNicStaticMac -VmName 'router-prod' -Role 'external'
            $mac.HyperV.Substring(0, 2) | Should -Be '02'
            $mac.Netplan.Substring(0, 2) | Should -Be '02'
        }
    }

    # ------------------------------------------------------------------
    Context 'determinism' {
    # ------------------------------------------------------------------
        # The router seed (built first) and the VM-creation step
        # (which pins the MAC on the adapter) must agree without any
        # extra IPC. Determinism from VmName + Role gives that.

        It 'returns the same MAC for the same VmName + Role across calls' {
            $a = Get-RouterNicStaticMac -VmName 'router-prod' -Role 'external'
            $b = Get-RouterNicStaticMac -VmName 'router-prod' -Role 'external'
            $a.HyperV  | Should -Be $b.HyperV
            $a.Netplan | Should -Be $b.Netplan
        }
    }

    # ------------------------------------------------------------------
    Context 'role separation' {
    # ------------------------------------------------------------------

        It 'returns different MACs for external vs private on the same VM' {
            # Two NICs on one router must have distinct MACs or
            # netplan match-by-MAC cannot tell them apart.
            $ext  = Get-RouterNicStaticMac -VmName 'router-prod' -Role 'external'
            $priv = Get-RouterNicStaticMac -VmName 'router-prod' -Role 'private'
            $ext.HyperV | Should -Not -Be $priv.HyperV
        }

        It 'returns different MACs for the same role on different VMs' {
            $a = Get-RouterNicStaticMac -VmName 'router-prod' -Role 'external'
            $b = Get-RouterNicStaticMac -VmName 'router-e2e'  -Role 'external'
            $a.HyperV | Should -Not -Be $b.HyperV
        }
    }

    # ------------------------------------------------------------------
    Context 'parameter validation' {
    # ------------------------------------------------------------------

        It 'rejects an empty VmName' {
            { Get-RouterNicStaticMac -VmName '' -Role 'external' } |
                Should -Throw
        }

        It 'rejects an unknown Role' {
            { Get-RouterNicStaticMac -VmName 'router-prod' -Role 'wan' } |
                Should -Throw
        }
    }
}
