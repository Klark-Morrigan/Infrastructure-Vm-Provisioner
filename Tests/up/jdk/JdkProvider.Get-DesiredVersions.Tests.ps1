BeforeAll {
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\jdk\JdkProvider.Get-DesiredVersions.ps1"

    # ConvertFrom-Json is used to build $VmConfig inputs so the test
    # shapes match exactly what the production code sees at runtime
    # (PSCustomObject for JSON objects, object[] for JSON arrays). Hand-
    # built hashtables would diverge from the real type surface and
    # could mask -is [PSCustomObject] regressions.
    function New-VmConfigFromJson {
        param(
            [Parameter(Mandatory)] [string] $Json,
            # Most tests need _jdkResolvedVersion stamped by
            # Invoke-JdkAcquisition. Pass $null to omit it (used by
            # the "throws when acquisition did not run" case).
            [string] $ResolvedVersion = '21.0.11+10-LTS'
        )
        $vm = $Json | ConvertFrom-Json
        if ($null -ne $ResolvedVersion) {
            $vm | Add-Member -NotePropertyName _jdkResolvedVersion `
                             -NotePropertyValue $ResolvedVersion -Force
        }
        return $vm
    }
}

Describe 'Get-JdkDesiredVersions' {

    # ----------------------------------------------------------------------
    Context 'field absent' {
    # ----------------------------------------------------------------------

        It 'returns $null so the orchestrator skips the provider' {
            $vm = New-VmConfigFromJson '{ "vmName": "x" }'
            $result = Get-JdkDesiredVersions -VmConfig $vm
            $result | Should -BeNullOrEmpty
            # Distinguish "$null" (skip) from "@()" (ensure-none): only
            # the latter satisfies -is [array].
            ($null -eq $result) | Should -BeTrue
        }
    }

    # ----------------------------------------------------------------------
    Context 'ensure-none signals' {
    # ----------------------------------------------------------------------

        It 'returns @() for explicit null' {
            $vm = New-VmConfigFromJson '{ "javaDevKit": null }'
            $result = Get-JdkDesiredVersions -VmConfig $vm
            # Wrap before .Count: a $null pipeline yields a scalar under
            # strict mode, so @() / ,$result normalises it to an array.
            ,$result -is [array] | Should -BeTrue
            @($result).Count   | Should -Be 0
        }

        It 'survives the call-operator invocation path without unrolling to $null' {
            # The reconciler invokes provider operations through closures
            # (see Get-JdkProvider.ps1's scriptblock wrappers). In that
            # path, a bare `return @()` collapses to $null on the way
            # back out, which the reconciler then misreads as "skip
            # this provider" instead of "ensure none installed".
            # The fix uses `,@()` to preserve array shape across the
            # function boundary. This test reproduces the exact call
            # shape (& on a scriptblock wrapping the function) so a
            # future regression to `return @()` fails here.
            $vm = New-VmConfigFromJson '{ "javaDevKit": null }'
            $wrapper = { param($v) Get-JdkDesiredVersions -VmConfig $v }
            $result  = & $wrapper $vm
            ($null -eq $result) | Should -BeFalse -Because 'closure return must not unroll to $null'
            ($result -is [array]) | Should -BeTrue
            @($result).Count    | Should -Be 0
        }

        It 'returns @() for explicit empty list' {
            $vm = New-VmConfigFromJson '{ "javaDevKit": [] }'
            $result = Get-JdkDesiredVersions -VmConfig $vm
            ,$result -is [array] | Should -BeTrue
            @($result).Count   | Should -Be 0
        }
    }

    # ----------------------------------------------------------------------
    Context 'scalar shape (legacy single-JDK)' {
    # ----------------------------------------------------------------------

        It 'wraps a scalar object into a one-element Spec array with the resolved version' {
            $vm = New-VmConfigFromJson -ResolvedVersion '21.0.5+11-LTS' -Json @'
{ "javaDevKit": { "vendor": "temurin", "version": "21.0.5" } }
'@
            $result = Get-JdkDesiredVersions -VmConfig $vm

            @($result).Count            | Should -Be 1
            $result[0].Provider         | Should -Be 'javaDevKit'
            $result[0].Vendor           | Should -Be 'temurin'
            # Version is the RESOLVED form so the reconciler diff
            # matches the manifest's stored version on no-op reruns.
            $result[0].Version          | Should -Be '21.0.5+11-LTS'
            # RequestedVersion preserves the operator's literal pin
            # for diagnostic / display purposes; not used by the diff.
            $result[0].RequestedVersion | Should -Be '21.0.5'
        }
    }

    # ----------------------------------------------------------------------
    Context 'list shape' {
    # ----------------------------------------------------------------------

        It 'accepts a list of one entry and returns it as a Spec array with the resolved version' {
            $vm = New-VmConfigFromJson -ResolvedVersion '21.0.11+10-LTS' -Json @'
{ "javaDevKit": [ { "vendor": "temurin", "version": "21" } ] }
'@
            $result = Get-JdkDesiredVersions -VmConfig $vm

            @($result).Count            | Should -Be 1
            $result[0].Provider         | Should -Be 'javaDevKit'
            $result[0].Vendor           | Should -Be 'temurin'
            $result[0].Version          | Should -Be '21.0.11+10-LTS'
            $result[0].RequestedVersion | Should -Be '21'
        }

        It 'throws naming the missing _jdkResolvedVersion field' {
            # Acquisition did not run for this VM. Returning the literal
            # operator request as Spec.Version would force a phantom
            # reinstall on every run, so throw loud instead.
            $vm = New-VmConfigFromJson -ResolvedVersion $null -Json @'
{ "javaDevKit": { "vendor": "temurin", "version": "21" } }
'@
            { Get-JdkDesiredVersions -VmConfig $vm } |
                Should -Throw -ExpectedMessage '*_jdkResolvedVersion*Invoke-JdkAcquisition*'
        }

        It 'throws naming the observed count for a list of two' {
            $vm = New-VmConfigFromJson @'
{
  "javaDevKit": [
    { "vendor": "temurin", "version": "21" },
    { "vendor": "temurin", "version": "17" }
  ]
}
'@
            { Get-JdkDesiredVersions -VmConfig $vm } |
                Should -Throw -ExpectedMessage "*one JDK per VM*2*"
        }
    }
}
