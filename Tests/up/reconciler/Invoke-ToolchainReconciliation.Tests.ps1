BeforeAll {
    $reconcilerDir = "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\reconciler"

    . "$reconcilerDir\Provider-Contract.ps1"
    . "$reconcilerDir\Get-ProvisioningPlan.ps1"
    . "$reconcilerDir\Invoke-ToolchainReconciliation.ps1"

    # Shared call-order log. Each provider scriptblock pushes a tagged
    # entry, so a single test can assert both "this happened" and "it
    # happened in this order relative to that".
    function New-CallLog { New-Object System.Collections.Generic.List[string] }

    # Factory for a provider whose four scriptblocks are pre-wired to
    # the call log. Defaults to one desired and one installed record
    # with the same version, so the diff is NoOp - tests override per
    # scenario by passing different desired / installed sets, or
    # throwing scriptblocks for the failure scenarios.
    function New-FakeProvider {
        param(
            [Parameter(Mandatory)] [string] $Name,
            [Parameter(Mandatory)] $Log,
            [object] $Desired   = @(),
            [object] $Installed = @(),
            [scriptblock] $OnInstall   = $null,
            [scriptblock] $OnUninstall = $null
        )

        # Snapshot inputs into closure-local variables so the
        # GetNewClosure call below preserves the per-provider state.
        $providerName = $Name
        $localLog     = $Log
        $localDesired = $Desired
        $localInst    = $Installed

        $getDesired = {
            param($vm)
            $localLog.Add("$providerName.Get-DesiredVersions")
            return ,$localDesired
        }.GetNewClosure()

        $getInstalled = {
            param($ssh)
            $localLog.Add("$providerName.Get-InstalledVersions")
            return ,$localInst
        }.GetNewClosure()

        $install = if ($OnInstall) {
            $OnInstall
        } else {
            {
                param($ssh, $server, $spec)
                $localLog.Add("$providerName.Install-Version:$($spec.Version)")
            }.GetNewClosure()
        }

        $uninstall = if ($OnUninstall) {
            $OnUninstall
        } else {
            {
                param($ssh, $rec)
                $localLog.Add("$providerName.Uninstall-Version:$($rec.Version)")
            }.GetNewClosure()
        }

        [PSCustomObject]@{
            Name                  = $providerName
            'Get-DesiredVersions'   = $getDesired
            'Get-InstalledVersions' = $getInstalled
            'Install-Version'       = $install
            'Uninstall-Version'     = $uninstall
        }
    }

    function New-Spec {
        param([Parameter(Mandatory)][string] $Version, [string] $Provider)
        [PSCustomObject]@{ Provider = $Provider; Version = $Version }
    }

    function New-Installed {
        param([Parameter(Mandatory)][string] $Version, [string] $Provider)
        [PSCustomObject]@{
            Provider     = $Provider
            Version      = $Version
            InstallPath  = "/opt/$Provider-$Version"
            ManifestPath = "/var/lib/infra-provisioner/manifests/$Provider-$Version.json"
        }
    }
}

Describe 'Invoke-ToolchainReconciliation' {

    Context 'happy path' {

        It 'walks providers in array order, in the documented per-provider order' {
            $log = New-CallLog
            $p1 = New-FakeProvider -Name 'javaDevKit' -Log $log `
                    -Desired   @(New-Spec      -Version '21.0.6' -Provider 'javaDevKit') `
                    -Installed @(New-Installed -Version '21.0.5' -Provider 'javaDevKit')
            $p2 = New-FakeProvider -Name 'dotnetSdk'  -Log $log `
                    -Desired   @(New-Spec -Version '10.0.100' -Provider 'dotnetSdk') `
                    -Installed @()

            Invoke-ToolchainReconciliation `
                -SshClient 'ssh' -Server 'srv' -Vm 'vm' `
                -Providers @($p1, $p2)

            # Provider 1: desired -> installed -> uninstall(21.0.5) -> install(21.0.6).
            # Provider 2: desired -> installed -> install(10.0.100). Then p1 is
            # fully drained before p2 starts.
            $log | Should -Be @(
                'javaDevKit.Get-DesiredVersions',
                'javaDevKit.Get-InstalledVersions',
                'javaDevKit.Uninstall-Version:21.0.5',
                'javaDevKit.Install-Version:21.0.6',
                'dotnetSdk.Get-DesiredVersions',
                'dotnetSdk.Get-InstalledVersions',
                'dotnetSdk.Install-Version:10.0.100'
            )
        }

        It 'tolerates an empty providers array as a no-op' {
            { Invoke-ToolchainReconciliation `
                -SshClient 'ssh' -Server 'srv' -Vm 'vm' -Providers @() } |
                Should -Not -Throw
        }
    }

    Context 'skip semantics' {

        It 'does not query installed versions when Get-DesiredVersions returns $null' {
            $log = New-CallLog
            # Override Get-DesiredVersions to return $null directly. Using
            # the factory with -Desired $null would still funnel through
            # the unary-comma which produces a one-element array, so we
            # build the provider by hand here.
            $skipper = [PSCustomObject]@{
                Name                  = 'javaDevKit'
                'Get-DesiredVersions'   = { param($vm)
                    $log.Add('javaDevKit.Get-DesiredVersions')
                    return $null
                }.GetNewClosure()
                'Get-InstalledVersions' = { param($ssh)
                    $log.Add('javaDevKit.Get-InstalledVersions')
                    return @()
                }.GetNewClosure()
                'Install-Version'       = { param($a,$b,$c)
                    $log.Add('javaDevKit.Install-Version')
                }.GetNewClosure()
                'Uninstall-Version'     = { param($a,$b)
                    $log.Add('javaDevKit.Uninstall-Version')
                }.GetNewClosure()
            }
            $p2 = New-FakeProvider -Name 'dotnetSdk' -Log $log `
                    -Desired @() -Installed @()

            Invoke-ToolchainReconciliation `
                -SshClient 'ssh' -Server 'srv' -Vm 'vm' `
                -Providers @($skipper, $p2)

            $log | Should -Be @(
                'javaDevKit.Get-DesiredVersions',
                'dotnetSdk.Get-DesiredVersions',
                'dotnetSdk.Get-InstalledVersions'
            )
        }
    }

    Context 'per-provider failure isolation' {

        It 'continues to the next provider when one Install-Version throws' {
            $log = New-CallLog
            $p1 = New-FakeProvider -Name 'javaDevKit' -Log $log `
                    -Desired   @(New-Spec -Version '21.0.6' -Provider 'javaDevKit') `
                    -Installed @() `
                    -OnInstall { param($a,$b,$spec)
                        throw "boom from javaDevKit on $($spec.Version)"
                    }
            $p2 = New-FakeProvider -Name 'dotnetSdk' -Log $log `
                    -Desired   @(New-Spec -Version '10.0.100' -Provider 'dotnetSdk') `
                    -Installed @()

            $err = $null
            try {
                Invoke-ToolchainReconciliation `
                    -SshClient 'ssh' -Server 'srv' -Vm 'vm' `
                    -Providers @($p1, $p2)
            } catch { $err = $_ }

            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Message | Should -Match 'javaDevKit'
            $err.Exception.Message | Should -Match 'boom from javaDevKit'
            # Second provider must still have been visited end-to-end.
            $log -contains 'dotnetSdk.Install-Version:10.0.100' | Should -BeTrue
        }

        It 'aggregates failures from every failing provider' {
            $log = New-CallLog
            $p1 = New-FakeProvider -Name 'javaDevKit' -Log $log `
                    -Desired   @(New-Spec -Version '21.0.6' -Provider 'javaDevKit') `
                    -Installed @() `
                    -OnInstall { param($a,$b,$c) throw 'jdk-fail' }
            $p2 = New-FakeProvider -Name 'dotnetSdk' -Log $log `
                    -Desired   @(New-Spec -Version '10.0.100' -Provider 'dotnetSdk') `
                    -Installed @() `
                    -OnInstall { param($a,$b,$c) throw 'dotnet-fail' }

            $err = $null
            try {
                Invoke-ToolchainReconciliation `
                    -SshClient 'ssh' -Server 'srv' -Vm 'vm' `
                    -Providers @($p1, $p2)
            } catch { $err = $_ }

            $err | Should -Not -BeNullOrEmpty
            $msg = $err.Exception.Message
            $msg | Should -Match 'javaDevKit'
            $msg | Should -Match 'dotnetSdk'
            $msg | Should -Match 'jdk-fail'
            $msg | Should -Match 'dotnet-fail'
            $msg | Should -Match '2 provider'
        }

        It 'surfaces a malformed provider as that provider''s failure, not as an abort' {
            $log = New-CallLog
            # Missing Install-Version - Assert-ToolchainProvider will
            # throw inside the loop, recording it as a per-provider
            # failure rather than aborting subsequent providers.
            $broken = [PSCustomObject]@{
                Name                  = 'brokenProvider'
                'Get-DesiredVersions'   = { @() }
                'Get-InstalledVersions' = { @() }
                'Uninstall-Version'     = { }
            }
            $p2 = New-FakeProvider -Name 'dotnetSdk' -Log $log `
                    -Desired @() -Installed @()

            $err = $null
            try {
                Invoke-ToolchainReconciliation `
                    -SshClient 'ssh' -Server 'srv' -Vm 'vm' `
                    -Providers @($broken, $p2)
            } catch { $err = $_ }

            $err.Exception.Message | Should -Match 'brokenProvider'
            # p2 still ran.
            $log -contains 'dotnetSdk.Get-DesiredVersions' | Should -BeTrue
        }
    }

    Context 'within-provider ordering' {

        It 'runs every Uninstall-Version before any Install-Version' {
            $log = New-CallLog
            # Two installed records that are not in desired, plus two
            # desired records that are not installed -> two uninstalls
            # followed by two installs. If installs ran first, the log
            # would interleave.
            $desired = @(
                New-Spec -Version '21.0.7' -Provider 'javaDevKit'
                New-Spec -Version '21.0.8' -Provider 'javaDevKit'
            )
            $installed = @(
                New-Installed -Version '21.0.5' -Provider 'javaDevKit'
                New-Installed -Version '21.0.6' -Provider 'javaDevKit'
            )
            $p1 = New-FakeProvider -Name 'javaDevKit' -Log $log `
                    -Desired $desired -Installed $installed

            Invoke-ToolchainReconciliation `
                -SshClient 'ssh' -Server 'srv' -Vm 'vm' `
                -Providers @($p1)

            $actions = @($log | Where-Object {
                $_ -cmatch '\.Install-Version' -or $_ -cmatch '\.Uninstall-Version'
            })
            # All uninstalls precede all installs. Walk indices in the
            # filtered slice so the assertion does not depend on the
            # absolute position of unrelated log lines. Case-sensitive
            # matchers because "Uninstall-Version" contains the
            # substring "install-Version" under default case-insensitive
            # matching.
            $firstInstallIdx  = -1
            $lastUninstallIdx = -1
            for ($i = 0; $i -lt $actions.Count; $i++) {
                if ($actions[$i] -cmatch 'Uninstall-Version') {
                    $lastUninstallIdx = $i
                } elseif ($firstInstallIdx -lt 0 -and $actions[$i] -cmatch 'Install-Version') {
                    $firstInstallIdx = $i
                }
            }
            $firstInstallIdx  | Should -BeGreaterThan -1
            $lastUninstallIdx | Should -BeGreaterThan -1
            $lastUninstallIdx | Should -BeLessThan $firstInstallIdx
        }
    }
}
