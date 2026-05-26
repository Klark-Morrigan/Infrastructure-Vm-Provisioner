BeforeAll {
    $reconcilerDir = "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\reconciler"

    . "$reconcilerDir\Provider-Contract.ps1"
    . "$reconcilerDir\Get-ProvisioningPlan.ps1"
    . "$reconcilerDir\Invoke-ToolchainReconciliation.ps1"

    # Children walker calls Read-VmManifest. Stub the function in test
    # scope and route the body through a script-scoped manifest table
    # so tests can register canned parent / child manifests without
    # standing up a real SSH stack.
    # Default to a no-children manifest for any path that the test did
    # NOT explicitly register, so legacy tests (built before the
    # children walker existed) are unaffected by the new pre-uninstall
    # manifest read.
    $script:ManifestsByPath = @{}
    function Read-VmManifest {
        [CmdletBinding()]
        param([object] $SshClient, [string] $Path)
        if ($script:ManifestsByPath.ContainsKey($Path)) {
            return $script:ManifestsByPath[$Path]
        }
        return [PSCustomObject]@{
            schemaVersion = 1
            children      = @()
        }
    }

    function Register-Manifest {
        param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)] $Manifest)
        $script:ManifestsByPath[$Path] = $Manifest
    }

    function Clear-Manifests { $script:ManifestsByPath.Clear() }

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

    Context 'children walker (Phase D nested providers)' {

        BeforeEach { Clear-Manifests }

        It 'is a no-op when the parent manifest has an empty children array' {
            $log = New-CallLog
            $parentInstalled = New-Installed -Version '21.0.5' -Provider 'javaDevKit'
            Register-Manifest -Path $parentInstalled.ManifestPath -Manifest ([PSCustomObject]@{
                schemaVersion = 1
                provider      = 'javaDevKit'
                version       = '21.0.5'
                ownedPaths    = @('/opt/javaDevKit-21.0.5')
                children      = @()
            })

            $parent = New-FakeProvider -Name 'javaDevKit' -Log $log `
                        -Desired   @() `
                        -Installed @($parentInstalled)

            Invoke-ToolchainReconciliation `
                -SshClient 'ssh' -Server 'srv' -Vm 'vm' `
                -Providers @($parent)

            # No child entries -> only the parent's Uninstall runs.
            $log | Should -Be @(
                'javaDevKit.Get-DesiredVersions',
                'javaDevKit.Get-InstalledVersions',
                'javaDevKit.Uninstall-Version:21.0.5'
            )
        }

        It 'dispatches the child provider Uninstall-Version BEFORE the parent Uninstall-Version' {
            $log = New-CallLog

            $childManifestPath  = '/var/lib/infra-provisioner/manifests/dotnetTools-rg-5.4.1.json'
            $parentInstalled    = New-Installed -Version '10.0.100' -Provider 'dotnetSdk'

            Register-Manifest -Path $parentInstalled.ManifestPath -Manifest ([PSCustomObject]@{
                schemaVersion = 1
                provider      = 'dotnetSdk'
                version       = '10.0.100'
                ownedPaths    = @('/opt/dotnet-10.0.100')
                children      = @(
                    [PSCustomObject]@{
                        provider     = 'dotnetTools'
                        manifestPath = $childManifestPath
                    }
                )
            })
            Register-Manifest -Path $childManifestPath -Manifest ([PSCustomObject]@{
                schemaVersion = 1
                provider      = 'dotnetTools'
                version       = '5.4.1'
                ownedPaths    = @('/opt/dotnet-10.0.100/tools/.store/reportgenerator')
                children      = @()
            })

            $parent = New-FakeProvider -Name 'dotnetSdk' -Log $log `
                        -Desired   @() `
                        -Installed @($parentInstalled)

            # Nested provider: ParentProvider set, no Desired / Installed
            # ever read because the orchestrator must NOT dispatch
            # nested providers in the main loop.
            $childProvider = [PSCustomObject]@{
                Name                    = 'dotnetTools'
                ParentProvider          = 'dotnetSdk'
                'Get-DesiredVersions'   = {
                    param($vm)
                    $log.Add('dotnetTools.Get-DesiredVersions (UNEXPECTED)')
                    return @()
                }.GetNewClosure()
                'Get-InstalledVersions' = {
                    param($ssh)
                    $log.Add('dotnetTools.Get-InstalledVersions (UNEXPECTED)')
                    return @()
                }.GetNewClosure()
                'Install-Version'       = {
                    param($a,$b,$c)
                    $log.Add('dotnetTools.Install-Version (UNEXPECTED)')
                }.GetNewClosure()
                'Uninstall-Version'     = {
                    param($ssh, $rec)
                    $log.Add("dotnetTools.Uninstall-Version:$($rec.Version):$($rec.InstallPath)")
                }.GetNewClosure()
            }

            Invoke-ToolchainReconciliation `
                -SshClient 'ssh' -Server 'srv' -Vm 'vm' `
                -Providers @($parent, $childProvider)

            $log | Should -Be @(
                'dotnetSdk.Get-DesiredVersions',
                'dotnetSdk.Get-InstalledVersions',
                'dotnetTools.Uninstall-Version:5.4.1:/opt/dotnet-10.0.100/tools/.store/reportgenerator',
                'dotnetSdk.Uninstall-Version:10.0.100'
            )
        }

        It 'warns and proceeds when a child entry references an unregistered provider' {
            $log = New-CallLog
            $parentInstalled = New-Installed -Version '10.0.100' -Provider 'dotnetSdk'

            Register-Manifest -Path $parentInstalled.ManifestPath -Manifest ([PSCustomObject]@{
                schemaVersion = 1
                provider      = 'dotnetSdk'
                version       = '10.0.100'
                ownedPaths    = @('/opt/dotnet-10.0.100')
                children      = @(
                    [PSCustomObject]@{
                        provider     = 'ghostProvider'
                        manifestPath = '/var/lib/infra-provisioner/manifests/ghostProvider-1.json'
                    }
                )
            })

            $parent = New-FakeProvider -Name 'dotnetSdk' -Log $log `
                        -Desired   @() `
                        -Installed @($parentInstalled)

            $warnings = @()
            Invoke-ToolchainReconciliation `
                -SshClient 'ssh' -Server 'srv' -Vm 'vm' `
                -Providers @($parent) `
                -WarningVariable warnings -WarningAction SilentlyContinue

            # Parent's Uninstall still ran - the warning is the lesser
            # evil compared to leaving the parent forever installed.
            $log -contains 'dotnetSdk.Uninstall-Version:10.0.100' | Should -BeTrue
            ($warnings -join ' ') | Should -Match 'ghostProvider'
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

    Context 'OnProviderComplete callback' {

        It 'fires once per top-level provider with name, elapsed, and no-error flag' {
            # The callback is the integration point used by the
            # timing layer to attribute per-provider work to its own
            # sub-step bucket; the orchestrator must invoke it once
            # per top-level provider regardless of dispatch shape.
            $log = New-CallLog
            $p1 = New-FakeProvider -Name 'javaDevKit' -Log $log `
                    -Desired @() -Installed @()
            $p2 = New-FakeProvider -Name 'dotnetSdk'  -Log $log `
                    -Desired @() -Installed @()

            $callbackLog = New-Object System.Collections.Generic.List[object]
            $callback = {
                param($providerName, $elapsedMs, $hadError)
                $callbackLog.Add([PSCustomObject]@{
                    Name      = $providerName
                    ElapsedMs = $elapsedMs
                    HadError  = $hadError
                })
            }.GetNewClosure()

            Invoke-ToolchainReconciliation `
                -SshClient 'ssh' -Server 'srv' -Vm 'vm' `
                -Providers @($p1, $p2) `
                -OnProviderComplete $callback

            $callbackLog.Count           | Should -Be 2
            $callbackLog[0].Name         | Should -Be 'javaDevKit'
            $callbackLog[0].HadError     | Should -Be $false
            $callbackLog[0].ElapsedMs    | Should -BeGreaterOrEqual 0
            $callbackLog[1].Name         | Should -Be 'dotnetSdk'
            $callbackLog[1].HadError     | Should -Be $false
        }

        It 'fires with hadError=$true when a provider Install-Version throws' {
            # A failed provider must still contribute its partial
            # duration so the timing report can show where the time
            # went. The orchestrator's per-provider failure isolation
            # is preserved - the second provider also gets a callback.
            $log = New-CallLog
            $p1 = New-FakeProvider -Name 'javaDevKit' -Log $log `
                    -Desired   @(New-Spec -Version '21.0.6' -Provider 'javaDevKit') `
                    -Installed @() `
                    -OnInstall { param($ssh, $server, $spec) throw 'boom' }
            $p2 = New-FakeProvider -Name 'dotnetSdk' -Log $log `
                    -Desired @() -Installed @()

            $callbackLog = New-Object System.Collections.Generic.List[object]
            $callback = {
                param($providerName, $elapsedMs, $hadError)
                $callbackLog.Add([PSCustomObject]@{
                    Name = $providerName; HadError = $hadError
                })
            }.GetNewClosure()

            { Invoke-ToolchainReconciliation `
                -SshClient 'ssh' -Server 'srv' -Vm 'vm' `
                -Providers @($p1, $p2) `
                -OnProviderComplete $callback } |
                Should -Throw '*javaDevKit*boom*'

            $callbackLog.Count       | Should -Be 2
            $callbackLog[0].Name     | Should -Be 'javaDevKit'
            $callbackLog[0].HadError | Should -Be $true
            $callbackLog[1].Name     | Should -Be 'dotnetSdk'
            $callbackLog[1].HadError | Should -Be $false
        }

        It 'swallows a throwing callback without aborting dispatch of subsequent providers' {
            # A buggy callback must not mask the orchestrator's
            # per-provider boundary. Surface it as a warning and keep
            # going; otherwise a tracking bug in the timing layer
            # would silently break provisioning.
            $log = New-CallLog
            $p1 = New-FakeProvider -Name 'javaDevKit' -Log $log -Desired @() -Installed @()
            $p2 = New-FakeProvider -Name 'dotnetSdk'  -Log $log -Desired @() -Installed @()

            $callback = { throw 'callback exploded' }

            { Invoke-ToolchainReconciliation `
                -SshClient 'ssh' -Server 'srv' -Vm 'vm' `
                -Providers @($p1, $p2) `
                -OnProviderComplete $callback } |
                Should -Not -Throw

            # Both providers must still have been dispatched - the log
            # captures Get-DesiredVersions on each one.
            @($log | Where-Object {
                $_ -eq 'javaDevKit.Get-DesiredVersions' }).Count | Should -Be 1
            @($log | Where-Object {
                $_ -eq 'dotnetSdk.Get-DesiredVersions' }).Count  | Should -Be 1
        }
    }
}
