BeforeAll {
    # Stub the per-software acquirer so the orchestrator's dispatch can
    # be asserted in isolation. Behaviour for Invoke-JdkAcquisition itself
    # lives in Tests/up/jdk/Invoke-JdkAcquisition.Tests.ps1.
    function Invoke-JdkAcquisition { param($Vm) }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\acquire\Invoke-VmAcquisitions.ps1"

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
}

Describe 'Invoke-VmAcquisitions' {

    Context 'no opt-in fields' {

        It 'is a no-op when no acquirer fields are set' {
            Mock Invoke-JdkAcquisition {}
            Invoke-VmAcquisitions -Vm (New-PlainVm)
            Should -Invoke Invoke-JdkAcquisition -Times 0
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
    }
}
