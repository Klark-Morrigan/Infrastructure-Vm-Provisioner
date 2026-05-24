BeforeAll {
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\reconciler\Get-ProvisioningPlan.ps1"

    # Tiny factories so each It-block reads as the scenario under test
    # rather than as boilerplate. Spec / Installed shapes mirror the
    # provider contract in Provider-Contract.ps1.
    function New-Spec {
        param(
            [Parameter(Mandatory)] [string] $Version,
            [string] $Provider = 'javaDevKit'
        )
        [PSCustomObject]@{
            Provider = $Provider
            Version  = $Version
        }
    }

    function New-Installed {
        param(
            [Parameter(Mandatory)] [string] $Version,
            [string] $Provider = 'javaDevKit'
        )
        [PSCustomObject]@{
            Provider     = $Provider
            Version      = $Version
            InstallPath  = "/opt/$Provider-$Version"
            ManifestPath = "/var/lib/infra-provisioner/manifests/$Provider-$Version.json"
        }
    }
}

Describe 'Get-ProvisioningPlan' {

    # ----------------------------------------------------------------------
    Context 'desired = $null (sub-field absent on VM JSON)' {
    # ----------------------------------------------------------------------

        It 'returns SkipProvider=$true and passes installed through as NoOp' {
            $installed = @(New-Installed -Version '21.0.5')

            $plan = Get-ProvisioningPlan `
                -DesiredVersions   $null `
                -InstalledVersions $installed `
                -ProviderName      'javaDevKit'

            $plan.SkipProvider          | Should -BeTrue
            $plan.ToInstall             | Should -BeNullOrEmpty
            $plan.ToUninstall           | Should -BeNullOrEmpty
            @($plan.NoOp).Count         | Should -Be 1
            @($plan.NoOp)[0].Version    | Should -Be '21.0.5'
        }

        It 'returns all-empty arrays when installed is also empty' {
            $plan = Get-ProvisioningPlan `
                -DesiredVersions   $null `
                -InstalledVersions @() `
                -ProviderName      'javaDevKit'

            $plan.SkipProvider | Should -BeTrue
            $plan.ToInstall    | Should -BeNullOrEmpty
            $plan.ToUninstall  | Should -BeNullOrEmpty
            $plan.NoOp         | Should -BeNullOrEmpty
        }
    }

    # ----------------------------------------------------------------------
    Context 'desired = @() (ensure none installed)' {
    # ----------------------------------------------------------------------

        It 'queues every installed record for uninstall' {
            $installed = @(
                New-Installed -Version '21.0.5'
                New-Installed -Version '21.0.6'
            )

            $plan = Get-ProvisioningPlan `
                -DesiredVersions   @() `
                -InstalledVersions $installed `
                -ProviderName      'javaDevKit'

            $plan.SkipProvider                          | Should -BeFalse
            @($plan.ToUninstall).Count                  | Should -Be 2
            @($plan.ToUninstall | ForEach-Object Version) | Should -Be @('21.0.5', '21.0.6')
            $plan.ToInstall                             | Should -BeNullOrEmpty
            $plan.NoOp                                  | Should -BeNullOrEmpty
        }

        It 'is a no-op when nothing is installed and desired is empty' {
            $plan = Get-ProvisioningPlan `
                -DesiredVersions   @() `
                -InstalledVersions @() `
                -ProviderName      'javaDevKit'

            $plan.SkipProvider | Should -BeFalse
            $plan.ToUninstall  | Should -BeNullOrEmpty
            $plan.ToInstall    | Should -BeNullOrEmpty
            $plan.NoOp         | Should -BeNullOrEmpty
        }
    }

    # ----------------------------------------------------------------------
    Context 'desired has entries' {
    # ----------------------------------------------------------------------

        It 'queues new versions for install when nothing is installed' {
            $plan = Get-ProvisioningPlan `
                -DesiredVersions   @(New-Spec -Version '21.0.5') `
                -InstalledVersions @() `
                -ProviderName      'javaDevKit'

            @($plan.ToInstall).Count       | Should -Be 1
            @($plan.ToInstall)[0].Version  | Should -Be '21.0.5'
            $plan.ToUninstall              | Should -BeNullOrEmpty
            $plan.NoOp                     | Should -BeNullOrEmpty
            $plan.SkipProvider             | Should -BeFalse
        }

        It 'classifies a matching version as NoOp' {
            $plan = Get-ProvisioningPlan `
                -DesiredVersions   @(New-Spec -Version '21.0.5') `
                -InstalledVersions @(New-Installed -Version '21.0.5') `
                -ProviderName      'javaDevKit'

            @($plan.NoOp).Count       | Should -Be 1
            @($plan.NoOp)[0].Version  | Should -Be '21.0.5'
            # NoOp carries the installed-side record so ManifestPath is available
            # for downstream logging / nested-provider walks.
            @($plan.NoOp)[0].ManifestPath | Should -Not -BeNullOrEmpty
            $plan.ToInstall   | Should -BeNullOrEmpty
            $plan.ToUninstall | Should -BeNullOrEmpty
        }

        It 'splits a version swap into uninstall-old + install-new' {
            $plan = Get-ProvisioningPlan `
                -DesiredVersions   @(New-Spec      -Version '10.0.100' -Provider 'dotnetSdk') `
                -InstalledVersions @(New-Installed -Version '10.0.099' -Provider 'dotnetSdk') `
                -ProviderName      'dotnetSdk'

            @($plan.ToInstall).Count        | Should -Be 1
            @($plan.ToInstall)[0].Version   | Should -Be '10.0.100'
            @($plan.ToUninstall).Count      | Should -Be 1
            @($plan.ToUninstall)[0].Version | Should -Be '10.0.099'
            $plan.NoOp                      | Should -BeNullOrEmpty
        }

        It 'handles mixed install / uninstall / noOp in one diff' {
            $desired = @(
                New-Spec -Version '21.0.5'   # noOp (already installed)
                New-Spec -Version '21.0.7'   # install (new)
            )
            $installed = @(
                New-Installed -Version '21.0.5'   # noOp
                New-Installed -Version '21.0.6'   # uninstall (no longer desired)
            )

            $plan = Get-ProvisioningPlan `
                -DesiredVersions   $desired `
                -InstalledVersions $installed `
                -ProviderName      'javaDevKit'

            @($plan.ToInstall   | ForEach-Object Version) | Should -Be @('21.0.7')
            @($plan.ToUninstall | ForEach-Object Version) | Should -Be @('21.0.6')
            @($plan.NoOp        | ForEach-Object Version) | Should -Be @('21.0.5')
        }
    }

    # ----------------------------------------------------------------------
    Context 'defensive: cross-provider installed record' {
    # ----------------------------------------------------------------------

        It 'throws naming both providers when an installed record is misrouted' {
            $installed = @(New-Installed -Version '21.0.5' -Provider 'javaDevKit')

            {
                Get-ProvisioningPlan `
                    -DesiredVersions   @() `
                    -InstalledVersions $installed `
                    -ProviderName      'dotnetSdk'
            } | Should -Throw -ExpectedMessage "*javaDevKit*dotnetSdk*"
        }
    }
}
