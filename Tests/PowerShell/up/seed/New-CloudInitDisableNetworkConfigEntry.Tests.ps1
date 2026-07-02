BeforeAll {
    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\up\seed\New-CloudInitDisableNetworkConfigEntry.ps1"
}

Describe 'New-CloudInitDisableNetworkConfigEntry' {

    It 'targets the documented disable-flag path' {
        (New-CloudInitDisableNetworkConfigEntry) |
            Should -Match 'path: /etc/cloud/cloud\.cfg\.d/99-disable-network-config\.cfg'
    }

    It 'writes the file with mode 0644' {
        (New-CloudInitDisableNetworkConfigEntry) |
            Should -Match "permissions: '0644'"
    }

    It 'carries the exact content cloud-init parses for the disable flag' {
        (New-CloudInitDisableNetworkConfigEntry) |
            Should -Match ([regex]::Escape("content: 'network: {config: disabled}'"))
    }

    It 'returns a write_files list-item (leading two-space dash)' {
        # The string is dropped straight into a write_files: block, so
        # the dash + indentation owns the YAML item shape.
        (New-CloudInitDisableNetworkConfigEntry) | Should -Match '^\s\s-\s'
    }
}
