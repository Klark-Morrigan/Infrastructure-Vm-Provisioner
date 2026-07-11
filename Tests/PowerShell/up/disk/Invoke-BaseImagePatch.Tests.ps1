# PSAvoidOverwritingBuiltInCmdlets is suppressed file-wide: the BeforeAll
# stubs deliberately shadow built-in cmdlets so Pester has a symbol to
# mock and no call reaches the real host. This is the test-double seam,
# not accidental shadowing.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidOverwritingBuiltInCmdlets', '',
    Justification = 'Test stubs deliberately shadow built-ins as a Pester mock seam')]
param()

BeforeAll {
    function Test-Path   { param($Path) }
    function New-Item    { param($ItemType, $Path, [switch]$Force) }
    function Mount-VHD   { param($Path, [switch]$NoDriveLetter, [switch]$PassThru) }
    function Dismount-VHD { param($Path) }

    # wsl stub - uses $args to avoid parameter-binding conflicts with the
    # -u and -e flags passed by the callers (see Invoke-DiskImageAcquisition
    # tests for the detailed explanation).
    function wsl { $global:LASTEXITCODE = 0 }

    # Assert-Wsl2Ready is owned by Common.PowerShell and unit-tested there.
    # Stub it here so this test file does not redundantly assert the same
    # readiness/install/throw paths; the consumer-side concerns are only
    # "do we call it" and "do we propagate its throw without continuing".
    function Assert-Wsl2Ready { }

    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\up\disk\Invoke-BaseImagePatch.ps1"

    # script-scoped so the It blocks below can read them; Pester v5 shares
    # BeforeAll script: variables with the container's tests.
    $script:BaseImage = 'C:\VHDs\ubuntu-24.04-server-cloudimg-amd64.vhdx'
    $script:Sentinel  = 'C:\VHDs\ubuntu-24.04-server-cloudimg-amd64.image-patched-v6'
}

Describe 'Invoke-BaseImagePatch' {

    # ------------------------------------------------------------------
    Context 'sentinel already present' {
    # ------------------------------------------------------------------
        # The sentinel file records that the patch was applied on a previous
        # run. All WSL2 operations must be skipped to avoid redundant work.

        It 'returns without calling Mount-VHD when the sentinel exists' {
            Mock Test-Path { $true }
            Mock Mount-VHD {}

            Invoke-BaseImagePatch -BaseImagePath $BaseImage -SentinelPath $Sentinel

            Should -Invoke Mount-VHD -Times 0
        }

        It 'returns without calling wsl when the sentinel exists' {
            Mock Test-Path { $true }
            Mock wsl {}

            Invoke-BaseImagePatch -BaseImagePath $BaseImage -SentinelPath $Sentinel

            Should -Invoke wsl -Times 0
        }
    }

    # ------------------------------------------------------------------
    Context 'WSL2 readiness delegated to Assert-Wsl2Ready' {
    # ------------------------------------------------------------------
        # The readiness/install/throw paths live in Common.PowerShell's
        # Assert-Wsl2Ready (and are covered by its tests there). Here we
        # only verify the consumer-side contract: we call the helper, and
        # if it throws we propagate the throw without proceeding to mount.

        It 'invokes Assert-Wsl2Ready after the sentinel check' {
            Mock Test-Path { $false }
            Mock Assert-Wsl2Ready {}
            # Mount-VHD throws to short-circuit before the WSL/lsblk
            # branch, which is not the subject of this test.
            Mock Mount-VHD { throw 'short-circuit after readiness check' }

            { Invoke-BaseImagePatch -BaseImagePath $BaseImage -SentinelPath $Sentinel } |
                Should -Throw

            Should -Invoke Assert-Wsl2Ready -Times 1 -Exactly
        }

        It 'does not call Mount-VHD when Assert-Wsl2Ready throws' {
            Mock Test-Path { $false }
            Mock Assert-Wsl2Ready { throw 'Wsl2NotReady: reboot required.' }
            Mock Mount-VHD {}

            { Invoke-BaseImagePatch -BaseImagePath $BaseImage -SentinelPath $Sentinel } |
                Should -Throw -ExpectedMessage 'Wsl2NotReady:*'

            Should -Invoke Mount-VHD -Times 0
        }
    }

    # ------------------------------------------------------------------
    Context 'wsl --mount --bare fails' {
    # ------------------------------------------------------------------
        # If the bare mount fails, the function throws and the finally block
        # must still dismount the VHD. The sentinel must not be created.

        BeforeEach {
            Mock Test-Path { $false }
            # Readiness lives in Common.PowerShell; stub it out so these
            # tests focus on the --bare-failure path.
            Mock Assert-Wsl2Ready {}
            Mock Mount-VHD { [PSCustomObject]@{ DiskNumber = 3 } }
            Mock Dismount-VHD {}
            Mock New-Item {}
            Mock wsl {
                if ($args -contains '--bare') { $global:LASTEXITCODE = 1; return 'error' }
                $global:LASTEXITCODE = 0; return ''
            }
        }

        It 'throws when wsl --mount --bare returns a non-zero exit code' {
            { Invoke-BaseImagePatch -BaseImagePath $BaseImage -SentinelPath $Sentinel } |
                Should -Throw -ExpectedMessage '*wsl --mount --bare failed*'
        }

        It 'calls Dismount-VHD in the finally block when wsl --mount --bare fails' {
            { Invoke-BaseImagePatch -BaseImagePath $BaseImage -SentinelPath $Sentinel } |
                Should -Throw

            Should -Invoke Dismount-VHD -Times 1 -Exactly -ParameterFilter {
                $Path -eq $BaseImage
            }
        }

        It 'does not create the sentinel file when wsl --mount --bare fails' {
            { Invoke-BaseImagePatch -BaseImagePath $BaseImage -SentinelPath $Sentinel } |
                Should -Throw

            Should -Invoke New-Item -Times 0
        }
    }

    # ------------------------------------------------------------------
    Context 'patch output is multi-line - sentinel parsed from the noise' {
    # ------------------------------------------------------------------
        # Regression guard. Patch 4 runs apt inside the chroot; apt stderr is
        # merged into the captured output, so the OK: sentinel is no longer
        # the first (or only) line. An early version anchored ^OK: on the
        # whole blob and threw on a perfectly successful bake because dozens
        # of apt lines preceded the sentinel (seen first in an E2E run). The
        # function must locate the OK: line wherever it lands and succeed.

        BeforeEach {
            Mock Test-Path { $false }
            Mock Assert-Wsl2Ready {}
            Mock Mount-VHD { [PSCustomObject]@{ DiskNumber = 7 } }
            Mock Dismount-VHD {}
            Mock New-Item {}

            # lsblk is called twice (before then after --bare); return one
            # extra device the second time so exactly one 'new' device is
            # detected. base64 is matched before lsblk so the encoded script
            # blob (which itself contains the word lsblk) cannot be mistaken
            # for an lsblk probe.
            $script:lsblkCalls = 0
            Mock wsl {
                $joined = "$args"
                if ($args -contains '--bare')  { $global:LASTEXITCODE = 0; return '' }
                if ($joined -match 'base64 -d') {
                    $global:LASTEXITCODE = 0
                    # apt chatter BEFORE the sentinel - the exact shape that
                    # broke the ^OK: anchor in the field.
                    return @(
                        'Get:1 http://archive.ubuntu.com/ubuntu noble InRelease [126 kB]'
                        'Reading package lists...'
                        'Setting up acl (2.3.2-1build1.1) ...'
                        'OK:/dev/sdh1:acl=0:99-nocloud.cfg README'
                    )
                }
                if ($joined -match 'noheadings') {
                    $global:LASTEXITCODE = 0
                    $script:lsblkCalls++
                    if ($script:lsblkCalls -eq 1) { return 'sda' }  # before
                    return @('sda', 'sdh')                          # after: sdh new
                }
                $global:LASTEXITCODE = 0; return ''
            }
        }

        It 'completes without throwing when OK: is not the first output line' {
            { Invoke-BaseImagePatch -BaseImagePath $BaseImage -SentinelPath $Sentinel } |
                Should -Not -Throw
        }

        It 'creates the sentinel after a successful multi-line bake' {
            Invoke-BaseImagePatch -BaseImagePath $BaseImage -SentinelPath $Sentinel

            Should -Invoke New-Item -Times 1 -Exactly -ParameterFilter {
                $Path -eq $Sentinel
            }
        }
    }
}
