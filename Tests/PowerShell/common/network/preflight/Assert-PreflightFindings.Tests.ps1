BeforeAll {
    $preflight = "$PSScriptRoot\..\..\..\..\..\hyper-v\ubuntu\PowerShell\common\network\preflight"
    . "$preflight\Assert-PreflightFindings.ps1"

    function New-FindingList {
        param([object[]] $Finding)

        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($f in $Finding) { $list.Add($f) }
        return , $list
    }

    function New-Finding {
        param([string] $Status, [string] $Label, [string] $Detail = '')

        [PSCustomObject]@{ Status = $Status; Label = $Label; Detail = $Detail }
    }
}

Describe 'Assert-PreflightFindings' {

    Context 'no FAIL findings' {

        It 'returns silently so callers do not have to branch' {
            $findings = New-FindingList @(
                (New-Finding -Status 'PASS' -Label 'switch exists'),
                (New-Finding -Status 'WARN' -Label 'switch type unusual')
            )

            { Assert-PreflightFindings -Findings $findings -SwitchName 'Sw' } |
                Should -Not -Throw
        }

        It 'returns silently on an empty accumulator' {
            { Assert-PreflightFindings -Findings (New-FindingList @()) -SwitchName 'Sw' } |
                Should -Not -Throw
        }
    }

    Context 'one or more FAIL findings' {

        It 'names the switch and the FAIL count' {
            $findings = New-FindingList @(
                (New-Finding -Status 'PASS' -Label 'switch exists'),
                (New-Finding -Status 'FAIL' -Label 'vNIC is Up' -Detail 'Status=Disabled.')
            )

            { Assert-PreflightFindings -Findings $findings -SwitchName 'ExternalSwitch-Shared' } |
                Should -Throw -ExpectedMessage "*'ExternalSwitch-Shared'*(1 FAIL)*"
        }

        It 'consolidates every FAIL into one throw rather than stopping at the first' {
            # The whole point of the accumulator: an operator gets the full
            # picture in one run instead of fixing and re-running N times.
            $findings = New-FindingList @(
                (New-Finding -Status 'FAIL' -Label 'first thing' -Detail 'fix one'),
                (New-Finding -Status 'PASS' -Label 'fine thing'),
                (New-Finding -Status 'FAIL' -Label 'second thing' -Detail 'fix two')
            )

            $message = { Assert-PreflightFindings -Findings $findings -SwitchName 'Sw' } |
                Should -Throw -PassThru

            $message.Exception.Message | Should -BeLike '*2 FAIL*'
            $message.Exception.Message | Should -BeLike '*first thing*'
            $message.Exception.Message | Should -BeLike '*second thing*'
        }

        It 'carries each finding''s Detail - the message is the remedy, not a count' {
            $multiLineDetail = "Restart-Service SharedAccess`n        Restart-Computer"
            $findings = New-FindingList @(
                (New-Finding -Status 'FAIL' `
                             -Label  'ICS DNS proxy answers' `
                             -Detail $multiLineDetail)
            )

            $message = { Assert-PreflightFindings -Findings $findings -SwitchName 'Sw' } |
                Should -Throw -PassThru

            # Multi-line details (a verdict plus the commands that carry it
            # out) must survive intact; the bullet only prefixes the first line.
            $message.Exception.Message | Should -BeLike '*Restart-Service SharedAccess*'
            $message.Exception.Message | Should -BeLike '*Restart-Computer*'
        }

        It 'ignores WARN - only FAIL aborts the run' {
            $findings = New-FindingList @(
                (New-Finding -Status 'WARN' -Label 'ICS host IP' -Detail 'Got 10.0.0.1.'),
                (New-Finding -Status 'FAIL' -Label 'route missing' -Detail 'no route')
            )

            $message = { Assert-PreflightFindings -Findings $findings -SwitchName 'Sw' } |
                Should -Throw -PassThru

            $message.Exception.Message | Should -BeLike '*1 FAIL*'
            $message.Exception.Message | Should -Not -BeLike '*ICS host IP*'
        }
    }
}
