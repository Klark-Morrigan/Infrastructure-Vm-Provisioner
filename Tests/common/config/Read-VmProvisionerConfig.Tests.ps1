<#
.SYNOPSIS
    Unit tests for Read-VmProvisionerConfig.

.DESCRIPTION
    Covers the bootstrap path that loads SecretManagement provider modules,
    reads the VmProvisionerConfig secret, and validates the JSON via
    ConvertFrom-VmConfigJson. The SecretStore is never touched - every
    external cmdlet is mocked so the suite runs in isolation.
#>

BeforeAll {
    # Stub cross-repo functions that ConvertFrom-VmConfigJson.ps1 expects
    # at dot-source time. Their real implementations live in
    # Common.PowerShell / Infrastructure.HyperV, which the test host
    # does not load. ConvertFrom-VmConfigJson itself is mocked per-test
    # via Pester, so these stubs only need to satisfy the dot-source.
    function Assert-RequiredProperties { param($Object, $Properties, $Context) }
    function Assert-VmFilesField {
        param($Vm, $AllowedSubFields, [switch] $AllowBulkEntries,
              $PostEntryValidator, $PostEntryValidatorContext)
    }
    function Assert-VmEnvVarsField { param($Vm) }

    # SecretManagement cmdlet stubs. Real implementations live in
    # Microsoft.PowerShell.SecretManagement, which is not installed on CI
    # runners. Pester 5's Mock cannot attach to a command that does not
    # exist in the session, so we provide function shells with matching
    # parameter surfaces. [CmdletBinding()] lets PowerShell wire up the
    # common parameters (-ErrorAction in particular) the same way the
    # real cmdlets do, so each test's ParameterFilter sees $ErrorAction
    # without us having to redeclare it. Each test then Mocks these
    # per-scenario.
    function Get-SecretVault {
        [CmdletBinding()]
        param([string] $Name)
    }
    function Get-Secret {
        [CmdletBinding()]
        param(
            [string] $Vault,
            [string] $Name,
            [switch] $AsPlainText
        )
    }

    function ConvertTo-Array {
        param([AllowNull()] $InputObject)
        if ($null -eq $InputObject) { return , @() }
        , @($InputObject)
    }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\common\config\Read-VmProvisionerConfig.ps1"

    # Suffix used by every happy-path call. Keeping it in one place means
    # a future rename of the suffix contract only touches one literal in
    # the test file; the asserted secret name and Write-Host text both
    # interpolate this value.
    $script:TestSuffix     = 'Production'
    $script:TestSecretName = "VmProvisionerConfig-$script:TestSuffix"
}

Describe 'Read-VmProvisionerConfig' {

    BeforeEach {
        # Default happy-path mocks. Individual tests override the ones
        # they need to fail.
        Mock Get-Module    { @{ Name = $Name } } -ParameterFilter { $ListAvailable }
        Mock Import-Module { }
        Mock Get-SecretVault { @{ Name = $Name } }
        Mock Get-Secret    { '[{"vmName":"node-01"}]' }
        Mock ConvertFrom-VmConfigJson {
            [PSCustomObject]@{ vmName = 'node-01' }
        }
        Mock Write-Host    { }
    }

    # ------------------------------------------------------------------
    Context 'provider modules missing' {
    # ------------------------------------------------------------------

        It 'throws the literal message when SecretManagement is missing' {
            Mock Get-Module { $null } -ParameterFilter {
                $ListAvailable -and
                $Name -eq 'Microsoft.PowerShell.SecretManagement'
            }
            { Read-VmProvisionerConfig -SecretSuffix $script:TestSuffix } | Should -Throw `
                "Module 'Microsoft.PowerShell.SecretManagement' is not installed. Run setup-secrets.ps1 first."
        }

        It 'throws the literal message when SecretStore is missing' {
            Mock Get-Module { $null } -ParameterFilter {
                $ListAvailable -and
                $Name -eq 'Microsoft.PowerShell.SecretStore'
            }
            { Read-VmProvisionerConfig -SecretSuffix $script:TestSuffix } | Should -Throw `
                "Module 'Microsoft.PowerShell.SecretStore' is not installed. Run setup-secrets.ps1 first."
        }
    }

    # ------------------------------------------------------------------
    Context 'provider module loading' {
    # ------------------------------------------------------------------

        It 'imports each provider module exactly once with -ErrorAction Stop' {
            Read-VmProvisionerConfig -SecretSuffix $script:TestSuffix | Out-Null
            Should -Invoke Import-Module -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'Microsoft.PowerShell.SecretManagement' -and
                $ErrorAction -eq 'Stop'
            }
            Should -Invoke Import-Module -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'Microsoft.PowerShell.SecretStore' -and
                $ErrorAction -eq 'Stop'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'vault discovery' {
    # ------------------------------------------------------------------

        It 'throws the literal message when the vault does not exist' {
            Mock Get-SecretVault { $null }
            { Read-VmProvisionerConfig -SecretSuffix $script:TestSuffix } | Should -Throw `
                "Vault 'VmProvisioner' not found. Run setup-secrets.ps1 first."
        }

        It 'does not call Get-Secret when the vault is missing' {
            Mock Get-SecretVault { $null }
            { Read-VmProvisionerConfig -SecretSuffix $script:TestSuffix } | Should -Throw
            Should -Invoke Get-Secret -Times 0 -Exactly
        }
    }

    # ------------------------------------------------------------------
    Context 'secret retrieval' {
    # ------------------------------------------------------------------

        It 'reads the secret with the expected parameters exactly once' {
            Read-VmProvisionerConfig -SecretSuffix $script:TestSuffix | Out-Null
            $expectedName = $script:TestSecretName
            Should -Invoke Get-Secret -Times 1 -Exactly -ParameterFilter {
                $Vault       -eq 'VmProvisioner' -and
                $Name        -eq $expectedName   -and
                $AsPlainText                     -and
                $ErrorAction -eq 'Stop'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'happy path' {
    # ------------------------------------------------------------------

        It 'returns the validated VM definitions as an array' {
            $result = Read-VmProvisionerConfig -SecretSuffix $script:TestSuffix
            # GetType().IsArray rather than -BeOfType, because Should pipes
            # unroll the array before the type check.
            $result.GetType().IsArray | Should -BeTrue
            $result.Count             | Should -Be 1
            $result[0].vmName         | Should -Be 'node-01'
        }

        It 'returns an array even when ConvertFrom-VmConfigJson yields a single object' {
            # Guards against the single-match pipeline unrolling trap.
            Mock ConvertFrom-VmConfigJson {
                [PSCustomObject]@{ vmName = 'only-one' }
            }
            $result = Read-VmProvisionerConfig -SecretSuffix $script:TestSuffix
            $result.GetType().IsArray | Should -BeTrue
            $result.Count             | Should -Be 1
        }

        It 'emits the "Reading ..." status line with the suffixed secret name' {
            Read-VmProvisionerConfig -SecretSuffix $script:TestSuffix | Out-Null
            $expectedLine = "Reading '$script:TestSecretName' from vault 'VmProvisioner' ..."
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                $Object -eq $expectedLine
            }
        }

        It 'emits the "[OK] Config validated" line with the VM count' {
            Read-VmProvisionerConfig -SecretSuffix $script:TestSuffix | Out-Null
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                $Object -eq '[OK] Config validated - 1 VM definition(s) found.'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'SecretSuffix parameter contract' {
    # ------------------------------------------------------------------

        # Pins the param attributes added in commit 0874c5d. Operator
        # invocations pass 'Production'; ephemeral fixtures pass their
        # own label. The mandatory + ValidateNotNullOrEmpty combination
        # is the safety guard that prevents a caller from silently
        # falling through to a default name and colliding with another
        # lifecycle's secret.

        It 'rejects missing -SecretSuffix with a ParameterBinding error' {
            { Read-VmProvisionerConfig } | Should -Throw `
                -ExpectedMessage '*SecretSuffix*'
        }

        It 'rejects an empty -SecretSuffix value (ValidateNotNullOrEmpty)' {
            { Read-VmProvisionerConfig -SecretSuffix '' } | Should -Throw
        }

        It 'rejects a $null -SecretSuffix value' {
            { Read-VmProvisionerConfig -SecretSuffix $null } | Should -Throw
        }

        It 'interpolates the suffix into the Get-Secret Name parameter' {
            Read-VmProvisionerConfig -SecretSuffix 'CI-42' | Out-Null
            Should -Invoke Get-Secret -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'VmProvisionerConfig-CI-42'
            }
        }

        It 'interpolates the suffix into the "Reading ..." status line' {
            Read-VmProvisionerConfig -SecretSuffix 'CI-42' | Out-Null
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                $Object -eq "Reading 'VmProvisionerConfig-CI-42' from vault 'VmProvisioner' ..."
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'error propagation' {
    # ------------------------------------------------------------------

        It 'propagates ConvertFrom-VmConfigJson failures unwrapped' {
            Mock ConvertFrom-VmConfigJson {
                throw 'Invalid JSON: oops'
            }
            { Read-VmProvisionerConfig -SecretSuffix $script:TestSuffix } | Should -Throw 'Invalid JSON: oops'
        }
    }
}
