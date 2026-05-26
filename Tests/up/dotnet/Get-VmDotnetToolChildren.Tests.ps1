BeforeAll {
    # Get-VmDotnetToolChildren is defined alongside Install-DotnetSdkVersion
    # because the parent provider owns the parent->child mapping (see the
    # helper's header for the dependency-direction rationale). Loading the
    # SDK Install-Version file is enough to make the helper visible.
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\dotnet\DotnetSdkProvider.Install-Version.ps1"
}

# Helper uses `return ,@()` so a direct call yields a single emitted
# value (the inner array). Bare-variable assignment captures that
# directly; wrapping the call in `@(...)` would COUNT that emitted
# value (the array itself) as one element rather than enumerating
# its contents. Existing tests on sister functions (e.g.
# Get-DotnetToolsDesiredVersions) follow the same `$x = call; @($x).Count`
# pattern - see the empty-array memory note for the producer-side
# rationale behind the comma operator.

Describe 'Get-VmDotnetToolChildren' {

    It 'returns @() when -Vm is $null' {
        # Defensive: the caller (Get-DotnetSdkProvider) is parameterised
        # by -Vm and may, in tests or future composition, hand a $null
        # through. The helper has no useful work to do; @() keeps the
        # parent manifest's children array empty rather than throwing.
        $result = Get-VmDotnetToolChildren -Vm $null
        @($result).Count | Should -Be 0
    }

    It 'returns @() when the VM has no dotnetTools field' {
        $vm = [PSCustomObject]@{ vmName = 'node-01' }
        $result = Get-VmDotnetToolChildren -Vm $vm
        @($result).Count | Should -Be 0
    }

    It 'returns @() when dotnetTools is $null (operator ensure-none)' {
        $vm = [PSCustomObject]@{ vmName = 'node-01'; dotnetTools = $null }
        $result = Get-VmDotnetToolChildren -Vm $vm
        @($result).Count | Should -Be 0
    }

    It 'returns @() when dotnetTools is an empty array' {
        $vm = [PSCustomObject]@{ vmName = 'node-01'; dotnetTools = @() }
        $result = Get-VmDotnetToolChildren -Vm $vm
        @($result).Count | Should -Be 0
    }

    It 'survives the call-operator path without unrolling to $null' {
        # Get-DotnetSdkProvider invokes this helper via `& $childEntriesFn`
        # at composition time. A bare `return @()` would unroll to $null
        # through that path (see feedback_powershell_return_empty_array
        # memory) - the children manifest field would then be $null
        # instead of an empty array, surprising the walker. This test
        # pins the closure-safe behaviour rather than just the direct-call
        # behaviour above.
        $vm      = [PSCustomObject]@{ vmName = 'node-01' }
        $wrapper = { param($v) Get-VmDotnetToolChildren -Vm $v }
        $result  = & $wrapper $vm
        ($null -eq $result)   | Should -BeFalse -Because 'closure return must not unroll to $null'
        ($result -is [array]) | Should -BeTrue
        @($result).Count      | Should -Be 0
    }

    It 'maps each dotnetTools entry to a { provider, manifestPath } record' {
        # manifestPath grammar must stay in lockstep with Write-VmManifest:
        # /var/lib/infra-provisioner/manifests/{provider}-{version}.json
        # and the tools-provider's `version` field is the composite
        # '{id}-{rawVersion}'. A regression in either side breaks the
        # walker silently (parent uninstall would leave orphan child
        # manifests behind), so this test pins both sides explicitly.
        $vm = [PSCustomObject]@{
            vmName      = 'node-01'
            dotnetTools = @(
                [PSCustomObject]@{ id = 'dotnet-reportgenerator-globaltool'; version = '5.4.4' }
            )
        }
        $result = Get-VmDotnetToolChildren -Vm $vm

        @($result).Count          | Should -Be 1
        $result[0].provider       | Should -Be 'dotnetTools'
        $result[0].manifestPath   | Should -Be '/var/lib/infra-provisioner/manifests/dotnetTools-dotnet-reportgenerator-globaltool-5.4.4.json'
    }

    It 'preserves declaration order across multiple entries' {
        # Walker visits children in the order they appear in the parent
        # manifest. Declaration order is the operator's intent and the
        # only stable ordering available (alphabetic by id would surprise
        # an operator who consciously ordered teardown).
        $vm = [PSCustomObject]@{
            vmName      = 'node-01'
            dotnetTools = @(
                [PSCustomObject]@{ id = 'tool-a'; version = '1.0.0' },
                [PSCustomObject]@{ id = 'tool-b'; version = '2.5.4' }
            )
        }
        $result = Get-VmDotnetToolChildren -Vm $vm

        @($result).Count        | Should -Be 2
        $result[0].manifestPath | Should -Be '/var/lib/infra-provisioner/manifests/dotnetTools-tool-a-1.0.0.json'
        $result[1].manifestPath | Should -Be '/var/lib/infra-provisioner/manifests/dotnetTools-tool-b-2.5.4.json'
    }
}
