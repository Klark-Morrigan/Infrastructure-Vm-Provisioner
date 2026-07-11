BeforeAll {
    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\common\config\Assert-VmUsernameField.ps1"

    # Build a VM definition by parsing JSON (rather than hand-rolling a
    # PSCustomObject) so the validator sees the same shape
    # ConvertFrom-VmConfigJson hands it at runtime.
    function New-VmWithUsername([string] $Username) {
        return ("{ `"vmName`": `"node-01`", `"username`": `"$Username`" }" |
            ConvertFrom-Json)
    }
}

Describe 'Assert-VmUsernameField' {

    Context 'safe usernames' {

        It 'accepts a non-colliding username' {
            { Assert-VmUsernameField -Vm (New-VmWithUsername 'ciadmin') } |
                Should -Not -Throw
        }

        It 'accepts the convention E2E uses (proven to provision)' {
            { Assert-VmUsernameField -Vm (New-VmWithUsername 'routeradmin') } |
                Should -Not -Throw
            { Assert-VmUsernameField -Vm (New-VmWithUsername 'e2eadmin') } |
                Should -Not -Throw
        }
    }

    Context 'reserved system-group usernames' {

        It "rejects 'admin' (the canonical collision) with a named cause" {
            { Assert-VmUsernameField -Vm (New-VmWithUsername 'admin') } |
                Should -Throw -ExpectedMessage "*username 'admin' collides with a pre-existing Ubuntu system group*"
        }

        It 'names the failing useradd behaviour in the message' {
            { Assert-VmUsernameField -Vm (New-VmWithUsername 'admin') } |
                Should -Throw -ExpectedMessage "*group admin exists*exit 9*"
        }

        It 'rejects other stock system-group names' -ForEach @(
            @{ Name = 'users' }, @{ Name = 'staff' }, @{ Name = 'games' },
            @{ Name = 'sudo'  }, @{ Name = 'backup' }, @{ Name = 'lxd' }
        ) {
            { Assert-VmUsernameField -Vm (New-VmWithUsername $Name) } |
                Should -Throw -ExpectedMessage "*collides with a pre-existing Ubuntu system group*"
        }

        It 'matches case-insensitively (usernames are conventionally lowercase)' {
            { Assert-VmUsernameField -Vm (New-VmWithUsername 'Admin') } |
                Should -Throw
            { Assert-VmUsernameField -Vm (New-VmWithUsername 'ADMIN') } |
                Should -Throw
        }
    }

    Context 'username absent' {

        It 'returns silently when username is absent (presence is the required-fields check)' {
            $vm = ('{ "vmName": "node-01" }' | ConvertFrom-Json)
            { Assert-VmUsernameField -Vm $vm } | Should -Not -Throw
        }
    }
}
