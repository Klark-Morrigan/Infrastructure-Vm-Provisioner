BeforeAll {
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\common\ui\Format-ElapsedBudgetWithGradient.ps1"

    # ANSI escape (ESC = 0x1B). Centralised so test strings can be
    # asserted directly against the helper output without re-encoding
    # the escape in every It.
    $script:ESC = [char]27

    # Linear blend used by the helper. Reproduced here as the test's
    # independent truth so a copy-paste regression in the helper is
    # caught.
    function Get-GradientTriple {
        param([double] $Ratio)
        $r = [int][Math]::Round( 80 + $Ratio * (255 -  80))
        $g = [int][Math]::Round(200 + $Ratio * (165 - 200))
        $b = [int][Math]::Round( 80 + $Ratio * (  0 -  80))
        @($r, $g, $b)
    }
}

Describe 'Format-ElapsedBudgetWithGradient' {

    Context 'success path' {

        It 'paints elapsed green at ratio 0 and leaves the budget uncoloured' {
            $out = Format-ElapsedBudgetWithGradient `
                       -ElapsedSeconds 0 -BudgetSeconds 600 -Succeeded $true

            $rgb = Get-GradientTriple -Ratio 0.0
            $out | Should -Be ("$script:ESC[38;2;$($rgb[0]);$($rgb[1]);$($rgb[2])m0s$script:ESC[0m / 600s")
        }

        It 'paints elapsed orange at ratio 1 and leaves the budget uncoloured' {
            $out = Format-ElapsedBudgetWithGradient `
                       -ElapsedSeconds 600 -BudgetSeconds 600 -Succeeded $true

            $rgb = Get-GradientTriple -Ratio 1.0
            $out | Should -Be ("$script:ESC[38;2;$($rgb[0]);$($rgb[1]);$($rgb[2])m600s$script:ESC[0m / 600s")
        }

        It 'blends mid-ratio elapsed between green and orange' {
            $out = Format-ElapsedBudgetWithGradient `
                       -ElapsedSeconds 300 -BudgetSeconds 600 -Succeeded $true

            $rgb = Get-GradientTriple -Ratio 0.5
            $out | Should -Be ("$script:ESC[38;2;$($rgb[0]);$($rgb[1]);$($rgb[2])m300s$script:ESC[0m / 600s")
        }

        It 'clamps the gradient when elapsed runs past budget' {
            # A slow poll iteration can land elapsed seconds just past
            # budget at exit (the loop only checks the deadline on
            # entry). The helper must clamp the gradient ratio at 1.0
            # so the success colour stays well-defined; without the
            # clamp, the linear blend would overshoot.
            $out = Format-ElapsedBudgetWithGradient `
                       -ElapsedSeconds 1200 -BudgetSeconds 600 -Succeeded $true

            $rgb = Get-GradientTriple -Ratio 1.0
            $out | Should -Be ("$script:ESC[38;2;$($rgb[0]);$($rgb[1]);$($rgb[2])m1200s$script:ESC[0m / 600s")
        }
    }

    Context 'timeout path' {

        It 'paints BOTH elapsed and budget red on timeout' {
            $out = Format-ElapsedBudgetWithGradient `
                       -ElapsedSeconds 600 -BudgetSeconds 600 -Succeeded $false

            $red = '38;2;220;70;70'
            $out | Should -Be ("$script:ESC[${red}m600s$script:ESC[0m / $script:ESC[${red}m600s$script:ESC[0m")
        }

        It 'uses red for elapsed when it exceeded budget on timeout' {
            $out = Format-ElapsedBudgetWithGradient `
                       -ElapsedSeconds 605 -BudgetSeconds 600 -Succeeded $false

            $red = '38;2;220;70;70'
            $out | Should -Be ("$script:ESC[${red}m605s$script:ESC[0m / $script:ESC[${red}m600s$script:ESC[0m")
        }
    }

    Context 'pure transform' {

        It 'returns a string and writes nothing to the host' {
            # Mock Write-Host so any accidental emit gets caught. The
            # helper must remain a pure formatter so callers decide
            # whether/how to render.
            Mock Write-Host { throw 'Format-* must not write to host' }

            $out = Format-ElapsedBudgetWithGradient `
                       -ElapsedSeconds 42 -BudgetSeconds 600 -Succeeded $true

            $out | Should -BeOfType [string]
        }
    }
}
