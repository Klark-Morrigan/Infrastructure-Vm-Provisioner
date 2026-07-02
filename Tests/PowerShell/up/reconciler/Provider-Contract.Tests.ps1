BeforeAll {
    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\up\reconciler\Provider-Contract.ps1"

    # Returns a freshly-built valid provider object so each test starts
    # from a known-good baseline and mutates one member to provoke the
    # error case under test. Built as a PSCustomObject because that is
    # the shape Get-<X>Provider helpers will produce in later steps.
    function New-ValidProvider {
        return [PSCustomObject]@{
            Name                    = 'javaDevKit'
            'Get-DesiredVersions'   = { param($vmConfig)  @() }
            'Get-InstalledVersions' = { param($sshClient) @() }
            'Install-Version'       = { param($sshClient, $server, $spec)      }
            'Uninstall-Version'     = { param($sshClient, $installed)          }
        }
    }
}

Describe 'Assert-ToolchainProvider' {

    # ----------------------------------------------------------------------
    Context 'valid provider' {
    # ----------------------------------------------------------------------

        It 'returns silently for a fully-formed PSCustomObject provider' {
            $provider = New-ValidProvider
            { Assert-ToolchainProvider -Provider $provider } | Should -Not -Throw
        }

        It 'returns silently for a fully-formed hashtable provider' {
            $provider = @{
                Name                    = 'dotnetSdk'
                'Get-DesiredVersions'   = { param($vmConfig)  @() }
                'Get-InstalledVersions' = { param($sshClient) @() }
                'Install-Version'       = { param($sshClient, $server, $spec)      }
                'Uninstall-Version'     = { param($sshClient, $installed)          }
            }
            { Assert-ToolchainProvider -Provider $provider } | Should -Not -Throw
        }
    }

    # ----------------------------------------------------------------------
    Context 'null or wrong container type' {
    # ----------------------------------------------------------------------

        It 'throws when the provider is $null' {
            { Assert-ToolchainProvider -Provider $null } |
                Should -Throw -ExpectedMessage "*must not be null*"
        }

        It 'throws when the provider is a plain string' {
            { Assert-ToolchainProvider -Provider 'not-a-provider' } |
                Should -Throw -ExpectedMessage "*PSCustomObject*hashtable*"
        }
    }

    # ----------------------------------------------------------------------
    Context 'missing required member' {
    # ----------------------------------------------------------------------

        # One case per required member: build a valid provider, remove
        # the member, assert the error names it. Hashtable form is used
        # here because Remove() on a hashtable is the simplest way to
        # produce a "member absent" provider without rewriting the
        # baseline per case.
        $requiredMembers = @(
            'Name',
            'Get-DesiredVersions',
            'Get-InstalledVersions',
            'Install-Version',
            'Uninstall-Version'
        )

        It "throws naming the missing member: <_>" -ForEach $requiredMembers {
            $member = $_
            $provider = @{
                Name                    = 'javaDevKit'
                'Get-DesiredVersions'   = { param($vmConfig)  @() }
                'Get-InstalledVersions' = { param($sshClient) @() }
                'Install-Version'       = { param($sshClient, $server, $spec)      }
                'Uninstall-Version'     = { param($sshClient, $installed)          }
            }
            $provider.Remove($member)

            { Assert-ToolchainProvider -Provider $provider } |
                Should -Throw -ExpectedMessage "*$member*"
        }
    }

    # ----------------------------------------------------------------------
    Context 'wrong member type' {
    # ----------------------------------------------------------------------

        It 'throws when Name is not a string' {
            $provider = New-ValidProvider
            $provider.Name = 42
            { Assert-ToolchainProvider -Provider $provider } |
                Should -Throw -ExpectedMessage "*Name*string*"
        }

        It 'throws when Name is an empty string' {
            $provider = New-ValidProvider
            $provider.Name = ''
            { Assert-ToolchainProvider -Provider $provider } |
                Should -Throw -ExpectedMessage "*Name*non-empty*"
        }

        $scriptblockMembers = @(
            'Get-DesiredVersions',
            'Get-InstalledVersions',
            'Install-Version',
            'Uninstall-Version'
        )

        It "throws when <_> is not a scriptblock" -ForEach $scriptblockMembers {
            $member = $_
            $provider = New-ValidProvider
            $provider.$member = 'not-a-scriptblock'
            { Assert-ToolchainProvider -Provider $provider } |
                Should -Throw -ExpectedMessage "*$member*scriptblock*"
        }
    }
}
