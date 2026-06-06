BeforeAll {
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\seed\Format-CloudInitLiteralBlock.ps1"
}

Describe 'Format-CloudInitLiteralBlock' {

    It 'prefixes a single-line body with six spaces' {
        (Format-CloudInitLiteralBlock -Body 'foo') | Should -Be '      foo'
    }

    It 'prefixes every line of a multi-line LF body with six spaces' {
        $body = "a`nb`nc"
        $expected = "      a`n      b`n      c"
        (Format-CloudInitLiteralBlock -Body $body) | Should -Be $expected
    }

    It 'normalises CRLF line endings to LF in the output' {
        # The output joins with LF regardless of input. Embedding
        # mixed-line-ending content under a YAML literal block stays
        # consistent with the rest of the cloud-config document.
        $body = "a`r`nb"
        $expected = "      a`n      b"
        (Format-CloudInitLiteralBlock -Body $body) | Should -Be $expected
    }

    It 'accepts an empty body and returns six spaces' {
        (Format-CloudInitLiteralBlock -Body '') | Should -Be '      '
    }
}
