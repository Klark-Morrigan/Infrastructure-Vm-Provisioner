BeforeAll {
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\seed\Initialize-SeedConfigDirectory.ps1"
}

Describe 'Initialize-SeedConfigDirectory' {

    It 'creates the directory when it does not exist' {
        Mock Test-Path { $false }
        Mock New-Item {}
        Initialize-SeedConfigDirectory -Path 'C:\seed-dir'
        Should -Invoke New-Item -Times 1 -Exactly -ParameterFilter {
            $ItemType -eq 'Directory' -and $Path -eq 'C:\seed-dir'
        }
    }

    It 'does not create the directory when it already exists' {
        Mock Test-Path { $true }
        Mock New-Item {}
        Initialize-SeedConfigDirectory -Path 'C:\seed-dir'
        Should -Invoke New-Item -Times 0
    }

    It 'rejects an empty Path' {
        { Initialize-SeedConfigDirectory -Path '' } | Should -Throw
    }
}
