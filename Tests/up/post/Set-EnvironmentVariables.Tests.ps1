BeforeAll {
    # Transport cmdlets are stubbed permissively before dot-source so the
    # function-under-test resolves them at parse time. Tests Mock them
    # individually for behavioural assertions.
    function Set-VmEnvironmentVariables {
        param($SshClient, $Entries, $BlockName, [switch]$NoSkipUnchanged)
    }
    # Stubbed so the file-server-not-called assertion can Mock it.
    # Set-EnvironmentVariables itself never references this cmdlet.
    function Add-VmFileServerFile { param($Server, $LocalPath) }
    # ConvertTo-Array ships in Infrastructure.Common in production. The
    # wrapper uses it to keep an empty entries array array-shaped after
    # property access (PSCustomObject -> object unwraps single-element
    # arrays). Tests reproduce its minimal contract.
    function ConvertTo-Array {
        param([Parameter(ValueFromPipeline)] $InputObject)
        if ($null -eq $InputObject) { return ,@() }
        return ,@($InputObject)
    }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\post\Set-EnvironmentVariables.ps1"

    # The orchestrator hands Set-EnvironmentVariables a live SshClient.
    # Tests use a stand-in that the function never inspects beyond passing
    # it through.
    $script:FakeSshClient = [PSCustomObject]@{ }

    function New-EnvVarsVm {
        param(
            [object[]] $Entries = @(
                [PSCustomObject]@{ name = 'FOO_HOME'; value = '/opt/foo' },
                [PSCustomObject]@{ name = 'BAR_VAR'; value = 'baz' }
            ),
            [string] $BlockName = 'vm-provisioner'
        )
        [PSCustomObject]@{
            vmName  = 'node-01'
            envVars = [PSCustomObject]@{
                blockName = $BlockName
                entries   = $Entries
            }
        }
    }
}

Describe 'Set-EnvironmentVariables' {

    BeforeEach {
        Mock Set-VmEnvironmentVariables { }
    }

    It 'calls Set-VmEnvironmentVariables exactly once with the supplied SshClient, entries, and blockName' {
        $vm = New-EnvVarsVm

        Set-EnvironmentVariables -SshClient $script:FakeSshClient -Vm $vm

        Should -Invoke Set-VmEnvironmentVariables -Times 1 -Exactly -ParameterFilter {
            $SshClient -eq $script:FakeSshClient -and
            $BlockName -eq 'vm-provisioner' -and
            $Entries.Count -eq 2 -and
            $Entries[0].name  -eq 'FOO_HOME' -and
            $Entries[0].value -eq '/opt/foo' -and
            $Entries[1].name  -eq 'BAR_VAR' -and
            $Entries[1].value -eq 'baz'
        }
    }

    It 'passes an empty entries array through unchanged (remove-the-block intent)' {
        # The transport treats entries:@() as "remove the managed block"; the
        # wrapper does not second-guess. Note: a Pester mock parameter filter
        # sees $null for an @() argument under PS strict mode, so the
        # assertion checks "not greater than 0" rather than ".Count -eq 0".
        $vm = New-EnvVarsVm -Entries @()

        Set-EnvironmentVariables -SshClient $script:FakeSshClient -Vm $vm

        Should -Invoke Set-VmEnvironmentVariables -Times 1 -Exactly -ParameterFilter {
            $BlockName -eq 'vm-provisioner' -and
            -not ($Entries -and $Entries.Count -gt 0)
        }
    }

    It 'rethrows transport failures with a message naming the VM and the inner exception text' {
        Mock Set-VmEnvironmentVariables { throw 'SSH channel closed' }

        { Set-EnvironmentVariables -SshClient $script:FakeSshClient `
                                   -Vm        (New-EnvVarsVm) } |
            Should -Throw -ExpectedMessage '*Set-EnvironmentVariables failed on node-01*SSH channel closed*'
    }

    It 'does not touch the file server (no $Server parameter, no Add-VmFileServerFile call)' {
        Mock Add-VmFileServerFile { }

        $vm = New-EnvVarsVm
        Set-EnvironmentVariables -SshClient $script:FakeSshClient -Vm $vm

        # The wrapper does not stage anything host-side; if it ever did,
        # passing $Server would be the right way - this test guards against
        # an accidental drift toward the JDK-step shape.
        Should -Not -Invoke Add-VmFileServerFile

        (Get-Command Set-EnvironmentVariables).Parameters.Keys |
            Should -Not -Contain 'Server'
    }
}
