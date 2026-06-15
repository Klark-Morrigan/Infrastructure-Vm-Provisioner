BeforeAll {
    # Stub Assert-RequiredProperties before dot-sourcing so the function exists
    # when ConvertFrom-VmConfigJson.ps1 is loaded. The real implementation
    # lives in Common.PowerShell, which is not required in the test
    # environment.
    function Assert-RequiredProperties {
        param($Object, $Properties, $Context)
    }

    # ConvertTo-Array is provided by Common.PowerShell at runtime.
    # Stub it here so the unit tests have no cross-repo dependency.
    function ConvertTo-Array {
        param([AllowNull()] $InputObject)
        if ($null -eq $InputObject) { return , @() }
        , @($InputObject)
    }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\common\config\ConvertFrom-VmConfigJson.ps1"

    # ConvertFrom-VmConfigJson.ps1 dot-sources Assert-JavaDevKitField.ps1, so
    # the real function is in scope. The wiring test below mocks it; behaviour
    # cases live in Assert-JavaDevKitField.Tests.ps1.
    #
    # Assert-VmFilesField is supplied by Infrastructure.HyperV at runtime.
    # Stub it here so the wiring test can mock it without loading the module.
    function Assert-VmFilesField {
        param(
            $Vm,
            $AllowedSubFields,
            [switch] $AllowBulkEntries,
            $PostEntryValidator,
            $PostEntryValidatorContext
        )
    }

    # Assert-VmEnvVarsField is supplied by Infrastructure.HyperV at runtime.
    # Stubbed here so wiring tests can mock it without loading the module.
    function Assert-VmEnvVarsField {
        param($Vm)
    }

    # Builds a minimal valid VM definition with all required fields populated.
    # Individual tests override specific fields as needed.
    function New-ValidVmJson([string] $vmName = 'node-01') {
        @"
{
    "vmName":            "$vmName",
    "cpuCount":          2,
    "ramGB":             4,
    "diskGB":            40,
    "ubuntuVersion":     "24.04",
    "username":          "admin",
    "password":          "s3cr3t",
    "ipAddress":         "10.0.0.10",
    "subnetMask":        "255.255.255.0",
    "gateway":           "10.0.0.1",
    "dns":               "8.8.8.8",
    "vmConfigPath":      "E:\\a_VMs\\Hyper-V\\Config",
    "vhdPath":           "E:\\a_VMs\\Hyper-V\\Disks",
    "privateSwitchName": "PrivateSwitch-Production"
}
"@
    }
}

Describe 'ConvertFrom-VmConfigJson' {

    # ------------------------------------------------------------------
    Context 'valid input' {
    # ------------------------------------------------------------------

        It 'returns a VM object for a single-object JSON array' {
            $result = @(ConvertFrom-VmConfigJson -Json "[$(New-ValidVmJson)]")
            $result | Should -HaveCount 1
            $result[0].vmName | Should -Be 'node-01'
        }

        It 'normalises a bare JSON object to a 1-element array (PS 5.1 unwrap)' {
            # ConvertFrom-Json in PS 5.1 unwraps a single-element JSON array
            # into a bare PSCustomObject. ConvertTo-Array normalises this so
            # callers always receive an array.
            $result = @(ConvertFrom-VmConfigJson -Json (New-ValidVmJson))
            $result | Should -HaveCount 1
        }

        It 'defaults kind to workload when absent' {
            $result = @(ConvertFrom-VmConfigJson -Json "[$(New-ValidVmJson)]")
            $result[0].kind | Should -Be 'workload'
        }

        It 'returns all VM objects for a multi-VM JSON array' {
            $json = "[$(New-ValidVmJson 'node-01'), $(New-ValidVmJson 'node-02')]"
            $result = @(ConvertFrom-VmConfigJson -Json $json)
            $result | Should -HaveCount 2
            $result[0].vmName | Should -Be 'node-01'
            $result[1].vmName | Should -Be 'node-02'
        }
    }

    # ------------------------------------------------------------------
    Context 'invalid JSON' {
    # ------------------------------------------------------------------

        It 'throws "Invalid JSON" for a malformed JSON string' {
            { ConvertFrom-VmConfigJson -Json '{not valid json' } |
                Should -Throw -ExpectedMessage '*Invalid JSON*'
        }

        It 'throws on an empty string' {
            # PS 5.1 rejects an empty [string] parameter before the function
            # body runs, so the error comes from parameter binding rather than
            # the "Invalid JSON" catch block. The function still throws - this
            # test pins that boundary behaviour.
            { ConvertFrom-VmConfigJson -Json '' } |
                Should -Throw -ExpectedMessage '*empty string*'
        }
    }

    # ------------------------------------------------------------------
    Context 'empty or non-object JSON' {
    # ------------------------------------------------------------------

        It 'throws when the JSON array is empty' {
            { ConvertFrom-VmConfigJson -Json '[]' } |
                Should -Throw -ExpectedMessage '*non-empty JSON array*'
        }

        It 'calls Assert-RequiredProperties on a JSON scalar (documents current behaviour)' {
            # ConvertFrom-Json succeeds for a quoted scalar like '"hello"', but
            # the result is a string, not a PSCustomObject. Assert-RequiredProperties
            # is called on it - this test pins the current behaviour so any
            # future guard added here is a deliberate, tested change.
            #
            # Per-kind validators (Assert-WorkloadVmField default-dispatched
            # for missing kind) get mocked to no-ops; their behaviour lives
            # in their own .Tests.ps1 files, and pinning the dispatch
            # contract here does not require their throw paths to fire.
            Mock Assert-RequiredProperties {}
            Mock Assert-WorkloadVmField {}
            { ConvertFrom-VmConfigJson -Json '"hello"' } | Should -Not -Throw
            Should -Invoke Assert-RequiredProperties -Times 1 -Exactly
        }
    }

    # ------------------------------------------------------------------
    Context 'Assert-RequiredProperties call contract' {
    # ------------------------------------------------------------------

        It 'calls Assert-RequiredProperties once per VM' {
            Mock Assert-RequiredProperties {}
            $json = "[$(New-ValidVmJson 'node-01'), $(New-ValidVmJson 'node-02')]"
            @(ConvertFrom-VmConfigJson -Json $json)
            Should -Invoke Assert-RequiredProperties -Times 2 -Exactly
        }

        It 'passes the vmName in the Context when vmName is present' {
            Mock Assert-RequiredProperties {}
            @(ConvertFrom-VmConfigJson -Json "[$(New-ValidVmJson 'node-01')]")
            Should -Invoke Assert-RequiredProperties -Times 1 -Exactly -ParameterFilter {
                $Context -like "*node-01*"
            }
        }

        It 'uses (unknown) in the Context when vmName is absent' {
            # A VM definition with no vmName field at all - the Context string
            # must fall back to (unknown) so the error is still meaningful.
            $json = '[{ "cpuCount": 2 }]'
            Mock Assert-RequiredProperties {}
            # Default-kind dispatch routes to Assert-WorkloadVmField; mock
            # to no-op so the dispatch contract test does not run into
            # the validator's required-field check.
            Mock Assert-WorkloadVmField {}
            @(ConvertFrom-VmConfigJson -Json $json)
            Should -Invoke Assert-RequiredProperties -Times 1 -Exactly -ParameterFilter {
                $Context -like "*(unknown)*"
            }
        }

        It 'throws when Assert-RequiredProperties throws (field validation failure)' {
            Mock Assert-RequiredProperties { throw "missing required field 'ipAddress'" }
            { ConvertFrom-VmConfigJson -Json "[$(New-ValidVmJson)]" } |
                Should -Throw -ExpectedMessage "*missing required field*"
        }
    }

    # ------------------------------------------------------------------
    Context 'Assert-JavaDevKitField wiring' {
    # ------------------------------------------------------------------

        It 'invokes Assert-JavaDevKitField once per VM' {
            # Wiring-only check. Behaviour cases for the validator itself
            # live in Assert-JavaDevKitField.Tests.ps1 - duplicating them
            # here would couple the caller's tests to its callee's rules.
            Mock Assert-JavaDevKitField {}
            $json = "[$(New-ValidVmJson 'node-01'), $(New-ValidVmJson 'node-02')]"
            @(ConvertFrom-VmConfigJson -Json $json)
            Should -Invoke Assert-JavaDevKitField -Times 2 -Exactly
        }

        It 'propagates a throw from Assert-JavaDevKitField' {
            Mock Assert-JavaDevKitField { throw "javaDevKit.version must be a string" }
            { ConvertFrom-VmConfigJson -Json "[$(New-ValidVmJson)]" } |
                Should -Throw -ExpectedMessage "*javaDevKit*"
        }
    }

    # ------------------------------------------------------------------
    Context 'Assert-DotnetSdkField wiring' {
    # ------------------------------------------------------------------

        It 'invokes Assert-DotnetSdkField once per VM' {
            # Wiring-only check. Behaviour cases for the validator itself
            # live in Assert-DotnetSdkField.Tests.ps1 - duplicating them
            # here would couple the caller's tests to its callee's rules.
            Mock Assert-DotnetSdkField {}
            $json = "[$(New-ValidVmJson 'node-01'), $(New-ValidVmJson 'node-02')]"
            @(ConvertFrom-VmConfigJson -Json $json)
            Should -Invoke Assert-DotnetSdkField -Times 2 -Exactly
        }

        It 'propagates a throw from Assert-DotnetSdkField' {
            Mock Assert-DotnetSdkField { throw "dotnetSdk.version must be a string" }
            { ConvertFrom-VmConfigJson -Json "[$(New-ValidVmJson)]" } |
                Should -Throw -ExpectedMessage "*dotnetSdk*"
        }
    }

    # ------------------------------------------------------------------
    Context 'Assert-DotnetToolsField wiring' {
    # ------------------------------------------------------------------

        It 'invokes Assert-DotnetToolsField once per VM' {
            # Wiring-only check. Behaviour cases for the validator itself
            # live in Assert-DotnetToolsField.Tests.ps1 - duplicating them
            # here would couple the caller's tests to its callee's rules.
            Mock Assert-DotnetToolsField {}
            $json = "[$(New-ValidVmJson 'node-01'), $(New-ValidVmJson 'node-02')]"
            @(ConvertFrom-VmConfigJson -Json $json)
            Should -Invoke Assert-DotnetToolsField -Times 2 -Exactly
        }

        It 'propagates a throw from Assert-DotnetToolsField' {
            Mock Assert-DotnetToolsField { throw "dotnetTools requires dotnetSdk on the same VM" }
            { ConvertFrom-VmConfigJson -Json "[$(New-ValidVmJson)]" } |
                Should -Throw -ExpectedMessage "*dotnetTools*"
        }

        It 'passes a VM with one dotnetSdk and one dotnetTools entry end-to-end' {
            # End-to-end through the real validator (no mock) - confirms
            # the happy-path schema fixture from problem.md parses cleanly.
            $core   = (New-ValidVmJson) -replace '\}\s*$', ''
            $extras = ', "dotnetSdk": { "channel": "10.0", "version": "10.0.100" }' +
                      ', "dotnetTools": [ { "id": "dotnet-reportgenerator-globaltool", "version": "5.4.4" } ]'
            $result = @(ConvertFrom-VmConfigJson -Json "[$core$extras }]")
            $result | Should -HaveCount 1
            $result[0].dotnetTools[0].id      | Should -Be 'dotnet-reportgenerator-globaltool'
            $result[0].dotnetTools[0].version | Should -Be '5.4.4'
        }

        It 'throws the cross-field error when dotnetTools is set without dotnetSdk' {
            # End-to-end through the real validator (no mock) - the
            # cross-field rule is the one observable behaviour ConvertFrom
            # callers depend on across the two .NET validators.
            $core   = (New-ValidVmJson) -replace '\}\s*$', ''
            $extras = ', "dotnetTools": [ { "id": "dotnet-ef", "version": "8.0.0" } ]'
            { ConvertFrom-VmConfigJson -Json "[$core$extras }]" } |
                Should -Throw -ExpectedMessage "*dotnetTools*dotnetSdk*"
        }
    }

    # ------------------------------------------------------------------
    Context 'Assert-VmFilesField wiring (Infrastructure.HyperV)' {
    # ------------------------------------------------------------------

        # Assert-VmFilesField is supplied by Infrastructure.HyperV at runtime.
        # The function is stubbed in BeforeAll alongside the other module
        # cmdlets so wiring tests can mock it without loading the module.

        It 'invokes Assert-VmFilesField once per VM with default sub-fields' {
            Mock Assert-VmFilesField {}
            $json = "[$(New-ValidVmJson 'node-01'), $(New-ValidVmJson 'node-02')]"
            @(ConvertFrom-VmConfigJson -Json $json)
            Should -Invoke Assert-VmFilesField -Times 2 -Exactly
        }

        It 'opts into bulk entries via -AllowBulkEntries' {
            # The opt-in is the only schema-surface change in this step.
            # Asserted here so a future caller cannot silently drop the
            # switch and lock the provisioner back into single-form-only.
            Mock Assert-VmFilesField {}
            @(ConvertFrom-VmConfigJson -Json "[$(New-ValidVmJson)]")
            Should -Invoke Assert-VmFilesField -Times 1 -Exactly -ParameterFilter {
                $AllowBulkEntries.IsPresent -and
                ($AllowedSubFields -join ',') -eq 'source,target'
            }
        }

        It 'propagates a throw from Assert-VmFilesField' {
            Mock Assert-VmFilesField { throw "files[0].source path does not exist" }
            { ConvertFrom-VmConfigJson -Json "[$(New-ValidVmJson)]" } |
                Should -Throw -ExpectedMessage "*files*"
        }
    }

    # ------------------------------------------------------------------
    Context 'Assert-VmEnvVarsField wiring (Infrastructure.HyperV)' {
    # ------------------------------------------------------------------

        # Per-rule shape assertions (blockName format, entry shape,
        # identifier syntax, duplicate detection) live in the upstream
        # Assert-VmEnvVarsField.Tests.ps1. Duplicating them here would
        # couple the caller's tests to the callee's rules - the wiring
        # tests below confirm only that we opted in by calling it and
        # that throws propagate.

        It 'invokes Assert-VmEnvVarsField once per VM' {
            Mock Assert-VmEnvVarsField {}
            $json = "[$(New-ValidVmJson 'node-01'), $(New-ValidVmJson 'node-02')]"
            @(ConvertFrom-VmConfigJson -Json $json)
            Should -Invoke Assert-VmEnvVarsField -Times 2 -Exactly
        }

        It 'passes the VM object to Assert-VmEnvVarsField' {
            Mock Assert-VmEnvVarsField {}
            @(ConvertFrom-VmConfigJson -Json "[$(New-ValidVmJson 'node-01')]")
            Should -Invoke Assert-VmEnvVarsField -Times 1 -Exactly -ParameterFilter {
                $Vm.vmName -eq 'node-01'
            }
        }

        It 'propagates a throw from Assert-VmEnvVarsField' {
            Mock Assert-VmEnvVarsField { throw "envVars.blockName must be a string" }
            { ConvertFrom-VmConfigJson -Json "[$(New-ValidVmJson)]" } |
                Should -Throw -ExpectedMessage "*envVars*"
        }

        It 'runs validators before applying the kind default' {
            # If validation threw mid-way after a default had been applied,
            # a later consumer could observe a half-defaulted VM object.
            # Pinning the order here keeps defaults strictly post-validation.
            Mock Assert-VmEnvVarsField { throw "envVars malformed" }
            $custom = (New-ValidVmJson | ConvertFrom-Json)
            { @(ConvertFrom-VmConfigJson -Json "[$(ConvertTo-Json $custom -Compress)]") } |
                Should -Throw
            $custom.PSObject.Properties['kind'] | Should -BeNullOrEmpty
        }
    }

    # ------------------------------------------------------------------
    Context 'envVars round-trip (object preserved on returned VM)' {
    # ------------------------------------------------------------------

        # Behaviour of the envVars validator (rejecting malformed shapes,
        # duplicate names, etc.) is covered upstream. These cases only
        # assert that opting in at the call site does not drop, rename,
        # or default any sub-field on the way through the schema layer.

        It 'preserves a well-formed envVars object on the returned VM' {
            $envVars = '{ "blockName": "e2e-ci", "entries": [{ "name": "FOO_HOME", "value": "/opt/foo" }, { "name": "BAR_VAR", "value": "baz" }] }'
            $core    = (New-ValidVmJson) -replace '\}\s*$', ''
            $result  = @(ConvertFrom-VmConfigJson -Json "[$core, ""envVars"": $envVars }]")
            $result[0].envVars.blockName       | Should -Be 'e2e-ci'
            $result[0].envVars.entries         | Should -HaveCount 2
            $result[0].envVars.entries[0].name | Should -Be 'FOO_HOME'
            $result[0].envVars.entries[0].value | Should -Be '/opt/foo'
            $result[0].envVars.entries[1].name | Should -Be 'BAR_VAR'
            $result[0].envVars.entries[1].value | Should -Be 'baz'
        }

        It 'preserves envVars.entries = [] (the "remove the block" intent)' {
            # The transport reads an empty entries array as "remove the
            # managed block". The schema layer must therefore pass it
            # through unchanged - dropping or defaulting it would silently
            # turn an explicit removal into a no-op.
            $envVars = '{ "blockName": "e2e-ci", "entries": [] }'
            $core    = (New-ValidVmJson) -replace '\}\s*$', ''
            $result  = @(ConvertFrom-VmConfigJson -Json "[$core, ""envVars"": $envVars }]")
            $result[0].envVars.blockName              | Should -Be 'e2e-ci'
            @($result[0].envVars.entries).Count       | Should -Be 0
        }

        It 'leaves envVars absent when the JSON omits it' {
            # Regression guard: this step is additive. The previous schema
            # had no envVars field at all and that intent must still parse.
            $result = @(ConvertFrom-VmConfigJson -Json "[$(New-ValidVmJson)]")
            $result[0].PSObject.Properties['envVars'] | Should -BeNullOrEmpty
        }
    }

    # ------------------------------------------------------------------
    Context 'kind field dispatch' {
    # ------------------------------------------------------------------
        # Behaviour of the router-specific rules lives in
        # Assert-RouterVmField.Tests.ps1; these cases only assert that
        # ConvertFrom-VmConfigJson dispatches by kind correctly:
        # workload (default) skips router rules; router invokes them
        # and propagates their throws.
        #
        # Router-VM JSON is built inline per test (no Context-local
        # helper) for the same reason the 'files round-trip' Context
        # does it: Pester 5 hoists BeforeAll function definitions but
        # not helpers defined inside a Context body.

        It 'accepts an explicit workload kind' {
            $core = (New-ValidVmJson) -replace '\}\s*$', ''
            $result = @(ConvertFrom-VmConfigJson -Json "[$core, ""kind"": ""workload"" }]")
            $result[0].kind | Should -Be 'workload'
        }

        It 'accepts a router kind with all router fields present' {
            $core = (New-ValidVmJson 'router-prod') -replace '\}\s*$', ''
            $extras = ', "kind": "router"' +
                      ', "externalSwitchName": "ExternalSwitch-Shared"' +
                      ', "externalAdapterName": "Ethernet"' +
                      ', "privateSwitchName": "PrivateSwitch-Production"' +
                      ', "privateIpAddress": "10.10.0.1"'
            $result = @(ConvertFrom-VmConfigJson -Json "[$core$extras }]")
            $result[0].kind                | Should -Be 'router'
            $result[0].externalSwitchName  | Should -Be 'ExternalSwitch-Shared'
            $result[0].externalAdapterName | Should -Be 'Ethernet'
            $result[0].privateSwitchName   | Should -Be 'PrivateSwitch-Production'
            $result[0].privateIpAddress    | Should -Be '10.10.0.1'
        }

        It 'rejects an unknown kind' {
            $core = (New-ValidVmJson) -replace '\}\s*$', ''
            { ConvertFrom-VmConfigJson -Json "[$core, ""kind"": ""firewall"" }]" } |
                Should -Throw -ExpectedMessage "*not recognised*"
        }

        It 'does not invoke Assert-RouterVmField on a workload VM' {
            # Default-kind path: router-specific rules must not fire so
            # workload VMs are not forced to declare router-only fields.
            Mock Assert-RouterVmField {}
            @(ConvertFrom-VmConfigJson -Json "[$(New-ValidVmJson)]")
            Should -Invoke Assert-RouterVmField -Times 0
        }

        It 'invokes Assert-RouterVmField on a router VM' {
            Mock Assert-RouterVmField {}
            $core = (New-ValidVmJson 'router-prod') -replace '\}\s*$', ''
            $extras = ', "kind": "router"' +
                      ', "externalSwitchName": "ExternalSwitch-Shared"' +
                      ', "externalAdapterName": "Ethernet"' +
                      ', "privateSwitchName": "PrivateSwitch-Production"' +
                      ', "privateIpAddress": "10.10.0.1"'
            @(ConvertFrom-VmConfigJson -Json "[$core$extras }]")
            Should -Invoke Assert-RouterVmField -Times 1 -Exactly -ParameterFilter {
                $Vm.vmName -eq 'router-prod'
            }
        }

        It 'propagates a throw from Assert-RouterVmField' {
            Mock Assert-RouterVmField {
                throw "router-prod: missing required field 'privateIpAddress'"
            }
            $core = (New-ValidVmJson 'router-prod') -replace '\}\s*$', ''
            $extras = ', "kind": "router"' +
                      ', "externalSwitchName": "ExternalSwitch-Shared"' +
                      ', "externalAdapterName": "Ethernet"' +
                      ', "privateSwitchName": "PrivateSwitch-Production"' +
                      ', "privateIpAddress": "10.10.0.1"'
            { ConvertFrom-VmConfigJson -Json "[$core$extras }]" } |
                Should -Throw -ExpectedMessage "*privateIpAddress*"
        }

        It 'throws end-to-end when a router VM omits privateIpAddress' {
            # End-to-end through the real validator (no mock) so the
            # router rejection message reaches callers unchanged. Every
            # other router-required field is present so the throw is
            # unambiguously about the missing privateIpAddress.
            # (privateSwitchName is now a base required field validated
            # by Assert-RequiredProperties - not Assert-RouterVmField - so
            # a different router-only field is omitted here.)
            $core = (New-ValidVmJson 'router-prod') -replace '\}\s*$', ''
            $extras = ', "kind": "router"' +
                      ', "externalSwitchName": "ExternalSwitch-Shared"' +
                      ', "externalAdapterName": "Ethernet"'
            { ConvertFrom-VmConfigJson -Json "[$core$extras }]" } |
                Should -Throw -ExpectedMessage "*privateIpAddress*"
        }

        It 'does not require router fields when kind is workload' {
            # Regression guard: the kind dispatch must leave existing
            # workload VMs untouched. A workload VM with no router
            # fields is still valid.
            { ConvertFrom-VmConfigJson -Json "[$(New-ValidVmJson)]" } |
                Should -Not -Throw
        }
    }

    # ------------------------------------------------------------------
    Context 'files round-trip (bulk-form entries preserved)' {
    # ------------------------------------------------------------------

        # Behaviour of the bulk validator itself (missing targetDir, unknown
        # sub-fields, etc.) is covered by Assert-VmFilesField's own tests
        # in Infrastructure-HyperV. These cases only assert that opting in
        # at the call site does not drop or rename any field on the way
        # through the schema layer.

        # Helper inlined per test: Pester 5 hoists function definitions in
        # BeforeAll, but a function defined inside a Context body is not in
        # scope for the It blocks. Building the JSON inline keeps the
        # round-trip cases self-contained without a Context-level BeforeAll.

        It 'preserves a single bulk entry on the returned VM' {
            $files = '[{ "pattern": "C:\\jars\\*.jar", "targetDir": "/opt/ci-jars" }]'
            $core  = (New-ValidVmJson) -replace '\}\s*$', ''
            $result = @(ConvertFrom-VmConfigJson -Json "[$core, ""files"": $files }]")
            $result[0].files | Should -HaveCount 1
            $result[0].files[0].pattern   | Should -Be 'C:\jars\*.jar'
            $result[0].files[0].targetDir | Should -Be '/opt/ci-jars'
        }

        It 'preserves a mixed single + bulk entry array in source order' {
            $files = @'
[
    { "source": "C:\\seed.json", "target": "/var/data/seed.json" },
    { "pattern": "C:\\jars\\*.jar", "targetDir": "/opt/ci-jars" }
]
'@
            $core  = (New-ValidVmJson) -replace '\}\s*$', ''
            $result = @(ConvertFrom-VmConfigJson -Json "[$core, ""files"": $files }]")
            $result[0].files | Should -HaveCount 2
            $result[0].files[0].source  | Should -Be 'C:\seed.json'
            $result[0].files[1].pattern | Should -Be 'C:\jars\*.jar'
        }

        It 'preserves the optional recurse and preserveRelativePath booleans' {
            $files = '[{ "pattern": "C:\\jars\\**\\*.jar", "targetDir": "/opt/ci-jars", "recurse": true, "preserveRelativePath": true }]'
            $core  = (New-ValidVmJson) -replace '\}\s*$', ''
            $result = @(ConvertFrom-VmConfigJson -Json "[$core, ""files"": $files }]")
            $result[0].files[0].recurse              | Should -BeTrue
            $result[0].files[0].preserveRelativePath | Should -BeTrue
        }
    }

    # ------------------------------------------------------------------
    Context 'partial output on mid-loop validation failure' {
    # ------------------------------------------------------------------

        It 'throws when the second VM fails validation' {
            # KNOWN BEHAVIOUR: the first VM is emitted to the pipeline before
            # the second VM is validated. If the caller wraps in @(), the array
            # will be incomplete when the throw is caught. This test documents
            # the behaviour so any future fix is deliberate and tested.
            #
            # $script: scope is required - Pester mock scriptblocks run in their
            # own scope and cannot read a local $callCount from the It block.
            $script:_mockCallCount = 0
            Mock Assert-RequiredProperties {
                $script:_mockCallCount++
                if ($script:_mockCallCount -eq 2) {
                    throw "missing required field 'ipAddress'"
                }
            }
            $json = "[$(New-ValidVmJson 'node-01'), $(New-ValidVmJson 'node-02')]"
            { @(ConvertFrom-VmConfigJson -Json $json) } |
                Should -Throw -ExpectedMessage "*missing required field*"
        }
    }
}
