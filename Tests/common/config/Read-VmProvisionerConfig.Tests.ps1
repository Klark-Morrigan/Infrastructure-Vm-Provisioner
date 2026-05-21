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
    # Infrastructure.Common / Infrastructure.HyperV, which the test host
    # does not load. ConvertFrom-VmConfigJson itself is mocked per-test
    # via Pester, so these stubs only need to satisfy the dot-source.
    function Assert-RequiredProperties { param($Object, $Properties, $Context) }
    function Assert-VmFilesField {
        param($Vm, $AllowedSubFields, [switch] $AllowBulkEntries,
              $PostEntryValidator, $PostEntryValidatorContext)
    }
    function Assert-VmEnvVarsField { param($Vm) }

    function ConvertTo-Array {
        param([AllowNull()] $InputObject)
        if ($null -eq $InputObject) { return , @() }
        , @($InputObject)
    }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\common\config\Read-VmProvisionerConfig.ps1"
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
            { Read-VmProvisionerConfig } | Should -Throw `
                "Module 'Microsoft.PowerShell.SecretManagement' is not installed. Run setup-secrets.ps1 first."
        }

        It 'throws the literal message when SecretStore is missing' {
            Mock Get-Module { $null } -ParameterFilter {
                $ListAvailable -and
                $Name -eq 'Microsoft.PowerShell.SecretStore'
            }
            { Read-VmProvisionerConfig } | Should -Throw `
                "Module 'Microsoft.PowerShell.SecretStore' is not installed. Run setup-secrets.ps1 first."
        }
    }

    # ------------------------------------------------------------------
    Context 'provider module loading' {
    # ------------------------------------------------------------------

        It 'imports each provider module exactly once with -ErrorAction Stop' {
            Read-VmProvisionerConfig | Out-Null
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
            { Read-VmProvisionerConfig } | Should -Throw `
                "Vault 'VmProvisioner' not found. Run setup-secrets.ps1 first."
        }

        It 'does not call Get-Secret when the vault is missing' {
            Mock Get-SecretVault { $null }
            { Read-VmProvisionerConfig } | Should -Throw
            Should -Invoke Get-Secret -Times 0 -Exactly
        }
    }

    # ------------------------------------------------------------------
    Context 'secret retrieval' {
    # ------------------------------------------------------------------

        It 'reads the secret with the expected parameters exactly once' {
            Read-VmProvisionerConfig | Out-Null
            Should -Invoke Get-Secret -Times 1 -Exactly -ParameterFilter {
                $Vault       -eq 'VmProvisioner'        -and
                $Name        -eq 'VmProvisionerConfig'  -and
                $AsPlainText                            -and
                $ErrorAction -eq 'Stop'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'happy path' {
    # ------------------------------------------------------------------

        It 'returns the validated VM definitions as an array' {
            $result = Read-VmProvisionerConfig
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
            $result = Read-VmProvisionerConfig
            $result.GetType().IsArray | Should -BeTrue
            $result.Count             | Should -Be 1
        }

        It 'emits the "Reading ..." status line' {
            Read-VmProvisionerConfig | Out-Null
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                $Object -eq "Reading 'VmProvisionerConfig' from vault 'VmProvisioner' ..."
            }
        }

        It 'emits the "[OK] Config validated" line with the VM count' {
            Read-VmProvisionerConfig | Out-Null
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                $Object -eq '[OK] Config validated - 1 VM definition(s) found.'
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
            { Read-VmProvisionerConfig } | Should -Throw 'Invalid JSON: oops'
        }
    }
}
