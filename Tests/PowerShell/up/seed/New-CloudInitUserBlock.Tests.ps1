BeforeAll {
    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\up\seed\New-CloudInitUserBlock.ps1"
}

Describe 'New-CloudInitUserBlock' {

    # ------------------------------------------------------------------
    Context 'username and password embedding' {
    # ------------------------------------------------------------------

        It 'embeds the username in the users[].name field' {
            (New-CloudInitUserBlock -Username 'admin' -Password 'p') |
                Should -Match '(?m)^\s+-\s+name:\s+"admin"\s*$'
        }

        It 'embeds the password in plain_text_passwd' {
            (New-CloudInitUserBlock -Username 'admin' -Password 'P@ssw0rd') |
                Should -Match '(?m)^\s+plain_text_passwd:\s+"P@ssw0rd"\s*$'
        }
    }

    # ------------------------------------------------------------------
    Context 'YAML escaping' {
    # ------------------------------------------------------------------

        It 'escapes backslashes in the username' {
            $body = New-CloudInitUserBlock -Username 'domain\admin' -Password 'p'
            $body | Should -Match ([regex]::Escape('name: "domain\\admin"'))
        }

        It 'escapes double quotes in the password' {
            $body = New-CloudInitUserBlock -Username 'admin' -Password 'P@ss"word'
            $body | Should -Match ([regex]::Escape('plain_text_passwd: "P@ss\"word"'))
        }
    }

    # ------------------------------------------------------------------
    Context 'fixed user shape' {
    # ------------------------------------------------------------------
        # These bits of policy live in the helper, not the caller, so
        # workload and router seeds cannot drift on (eg) the sudo line.

        It 'sets lock_passwd: false' {
            (New-CloudInitUserBlock -Username 'admin' -Password 'p') |
                Should -Match '(?m)^\s+lock_passwd:\s+false\s*$'
        }

        It 'sets a bash shell' {
            (New-CloudInitUserBlock -Username 'admin' -Password 'p') |
                Should -Match '(?m)^\s+shell:\s+/bin/bash\s*$'
        }

        It 'grants password-less sudo' {
            (New-CloudInitUserBlock -Username 'admin' -Password 'p') |
                Should -Match '(?m)^\s+sudo:\s+ALL=\(ALL\)\s+NOPASSWD:ALL\s*$'
        }

        It 'sets the expected groups list' {
            (New-CloudInitUserBlock -Username 'admin' -Password 'p') |
                Should -Match '(?m)^\s+groups:\s+\[adm,\s+cdrom,\s+dip,\s+plugdev,\s+lxd\]\s*$'
        }

        It 'enables ssh_pwauth' {
            (New-CloudInitUserBlock -Username 'admin' -Password 'p') |
                Should -Match '(?m)^ssh_pwauth:\s+true\s*$'
        }
    }
}
