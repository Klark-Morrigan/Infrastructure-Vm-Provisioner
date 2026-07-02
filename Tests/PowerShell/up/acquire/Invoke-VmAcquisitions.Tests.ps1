BeforeAll {
    # Stub the per-software acquirers so the orchestrator's dispatch can
    # be asserted in isolation. Behaviour for each acquirer itself lives
    # in its own Tests/up/<software>/ file.
    function Invoke-JdkAcquisition { param($Vm) }
    function Invoke-DotnetSdkAcquisition { param($Vm, $CacheDir) }
    function Invoke-DotnetToolAcquisition { param($Vm, $CacheDir) }
    # Stub the sub-step timer too so the dispatch tests stay focused on
    # which acquirer ran, not on whether the timing scaffolding is wired
    # up. The stub invokes the action directly so the underlying mocks
    # still record the call.
    function Invoke-WithSubStepTimer {
        param($Parent, $Name, [scriptblock] $Action)
        & $Action
    }

    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\up\acquire\Invoke-VmAcquisitions.ps1"

    function New-PlainVm {
        [PSCustomObject]@{ vmName = 'node-01' }
    }

    function New-VmWithJdkScalar {
        [PSCustomObject]@{
            vmName     = 'node-01'
            javaDevKit = [PSCustomObject]@{ vendor = 'temurin'; version = '21' }
        }
    }

    function New-VmWithJdkList {
        # List shape: javaDevKit can be an array of entries (v1 caps at
        # one).
        [PSCustomObject]@{
            vmName     = 'node-01'
            javaDevKit = @(
                [PSCustomObject]@{ vendor = 'temurin'; version = '21' }
            )
        }
    }

    function New-VmWithJdkNull {
        # "Ensure none installed" signal - drives the reconciler's
        # uninstall path.
        [PSCustomObject]@{
            vmName     = 'node-01'
            javaDevKit = $null
        }
    }

    function New-VmWithJdkEmptyList {
        [PSCustomObject]@{
            vmName     = 'node-01'
            javaDevKit = @()
        }
    }

    function New-VmWithDotnetScalar {
        [PSCustomObject]@{
            vmName    = 'node-01'
            vhdPath   = 'C:\cache'
            dotnetSdk = [PSCustomObject]@{ channel = '10.0'; version = '10.0.100' }
        }
    }

    function New-VmWithDotnetList {
        [PSCustomObject]@{
            vmName    = 'node-01'
            vhdPath   = 'C:\cache'
            dotnetSdk = @(
                [PSCustomObject]@{ channel = '10.0'; version = '10.0.100' }
            )
        }
    }

    function New-VmWithDotnetNull {
        [PSCustomObject]@{
            vmName    = 'node-01'
            dotnetSdk = $null
        }
    }

    function New-VmWithDotnetEmptyList {
        [PSCustomObject]@{
            vmName    = 'node-01'
            dotnetSdk = @()
        }
    }

    function New-VmWithDotnetTools {
        # Validator (Assert-DotnetToolsField) requires dotnetSdk too,
        # but the orchestrator does not re-check the cross-field rule;
        # fixture mirrors a realistic post-validation shape.
        [PSCustomObject]@{
            vmName      = 'node-01'
            vhdPath     = 'C:\cache'
            dotnetSdk   = [PSCustomObject]@{ channel = '10.0'; version = '10.0.100' }
            dotnetTools = @(
                [PSCustomObject]@{
                    id      = 'dotnet-reportgenerator-globaltool'
                    version = '5.4.4'
                }
            )
        }
    }

    function New-VmWithDotnetToolsNull {
        [PSCustomObject]@{
            vmName      = 'node-01'
            vhdPath     = 'C:\cache'
            dotnetTools = $null
        }
    }

    function New-VmWithDotnetToolsEmpty {
        [PSCustomObject]@{
            vmName      = 'node-01'
            vhdPath     = 'C:\cache'
            dotnetTools = @()
        }
    }
}

Describe 'Invoke-VmAcquisitions' {

    Context 'no opt-in fields' {

        It 'is a no-op when no acquirer fields are set' {
            Mock Invoke-JdkAcquisition {}
            Mock Invoke-DotnetSdkAcquisition {}
            Invoke-VmAcquisitions -Vm (New-PlainVm)
            Should -Invoke Invoke-JdkAcquisition -Times 0
            Should -Invoke Invoke-DotnetSdkAcquisition -Times 0
        }
    }

    Context 'javaDevKit present' {

        It 'dispatches Invoke-JdkAcquisition for the scalar shape' {
            Mock Invoke-JdkAcquisition {}
            Invoke-VmAcquisitions -Vm (New-VmWithJdkScalar)
            Should -Invoke Invoke-JdkAcquisition -Times 1 -Exactly `
                -ParameterFilter { $Vm.vmName -eq 'node-01' }
        }

        It 'dispatches Invoke-JdkAcquisition for the list shape' {
            Mock Invoke-JdkAcquisition {}
            Invoke-VmAcquisitions -Vm (New-VmWithJdkList)
            Should -Invoke Invoke-JdkAcquisition -Times 1 -Exactly `
                -ParameterFilter { $Vm.vmName -eq 'node-01' }
        }

        It 'skips Invoke-JdkAcquisition when javaDevKit is null (ensure-none)' {
            # The reconciler's uninstall path has nothing to acquire; an
            # Adoptium API call here would just burn a cache miss.
            Mock Invoke-JdkAcquisition {}
            Invoke-VmAcquisitions -Vm (New-VmWithJdkNull)
            Should -Invoke Invoke-JdkAcquisition -Times 0
        }

        It 'skips Invoke-JdkAcquisition when javaDevKit is an empty list (ensure-none)' {
            Mock Invoke-JdkAcquisition {}
            Invoke-VmAcquisitions -Vm (New-VmWithJdkEmptyList)
            Should -Invoke Invoke-JdkAcquisition -Times 0
        }

        It 'does not dispatch Invoke-DotnetSdkAcquisition when only javaDevKit is set' {
            Mock Invoke-JdkAcquisition {}
            Mock Invoke-DotnetSdkAcquisition {}
            Invoke-VmAcquisitions -Vm (New-VmWithJdkScalar)
            Should -Invoke Invoke-DotnetSdkAcquisition -Times 0
        }
    }

    Context 'dotnetSdk present' {

        It 'dispatches Invoke-DotnetSdkAcquisition for the scalar shape with vhdPath as CacheDir' {
            # Asserts the orchestrator forwards the per-VM cache root
            # so the dotnet acquirer lands tarballs next to JDK ones.
            Mock Invoke-DotnetSdkAcquisition {}
            Invoke-VmAcquisitions -Vm (New-VmWithDotnetScalar)
            Should -Invoke Invoke-DotnetSdkAcquisition -Times 1 -Exactly `
                -ParameterFilter {
                    $Vm.vmName -eq 'node-01' -and $CacheDir -eq 'C:\cache'
                }
        }

        It 'dispatches Invoke-DotnetSdkAcquisition for the list shape with vhdPath as CacheDir' {
            Mock Invoke-DotnetSdkAcquisition {}
            Invoke-VmAcquisitions -Vm (New-VmWithDotnetList)
            Should -Invoke Invoke-DotnetSdkAcquisition -Times 1 -Exactly `
                -ParameterFilter {
                    $Vm.vmName -eq 'node-01' -and $CacheDir -eq 'C:\cache'
                }
        }

        It 'skips Invoke-DotnetSdkAcquisition when dotnetSdk is null (ensure-none)' {
            # Same rationale as the JDK skip: the reconciler's uninstall
            # path reads the on-VM manifest, not the host cache, so a
            # Microsoft release-metadata call would be wasted work.
            Mock Invoke-DotnetSdkAcquisition {}
            Invoke-VmAcquisitions -Vm (New-VmWithDotnetNull)
            Should -Invoke Invoke-DotnetSdkAcquisition -Times 0
        }

        It 'skips Invoke-DotnetSdkAcquisition when dotnetSdk is an empty list (ensure-none)' {
            Mock Invoke-DotnetSdkAcquisition {}
            Invoke-VmAcquisitions -Vm (New-VmWithDotnetEmptyList)
            Should -Invoke Invoke-DotnetSdkAcquisition -Times 0
        }

        It 'does not dispatch Invoke-JdkAcquisition when only dotnetSdk is set' {
            Mock Invoke-JdkAcquisition {}
            Mock Invoke-DotnetSdkAcquisition {}
            Invoke-VmAcquisitions -Vm (New-VmWithDotnetScalar)
            Should -Invoke Invoke-JdkAcquisition -Times 0
        }
    }

    Context 'dotnetTools present' {

        It 'dispatches Invoke-DotnetToolAcquisition with vhdPath as CacheDir' {
            # Asserts the orchestrator forwards the per-VM cache root
            # so the .nupkg + lockfile artefacts land alongside the SDK
            # tarball - same cache slot, different file prefixes.
            Mock Invoke-DotnetToolAcquisition {}
            Invoke-VmAcquisitions -Vm (New-VmWithDotnetTools)
            Should -Invoke Invoke-DotnetToolAcquisition -Times 1 -Exactly `
                -ParameterFilter {
                    $Vm.vmName -eq 'node-01' -and $CacheDir -eq 'C:\cache'
                }
        }

        It 'skips Invoke-DotnetToolAcquisition when dotnetTools is null (ensure-none)' {
            # Same rationale as the SDK skip: no nuget.org round-trip
            # is needed when the reconciler will just walk an empty
            # desired set.
            Mock Invoke-DotnetToolAcquisition {}
            Invoke-VmAcquisitions -Vm (New-VmWithDotnetToolsNull)
            Should -Invoke Invoke-DotnetToolAcquisition -Times 0
        }

        It 'skips Invoke-DotnetToolAcquisition when dotnetTools is an empty array (ensure-none)' {
            Mock Invoke-DotnetToolAcquisition {}
            Invoke-VmAcquisitions -Vm (New-VmWithDotnetToolsEmpty)
            Should -Invoke Invoke-DotnetToolAcquisition -Times 0
        }
    }
}
