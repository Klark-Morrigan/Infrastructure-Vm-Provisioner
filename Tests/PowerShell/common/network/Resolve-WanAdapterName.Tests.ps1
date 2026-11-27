BeforeAll {

    # Host-only cmdlets, stubbed so each test decides what the host holds.
    function Get-WirelessNetAdapter { }
    function Get-NetAdapter { param([switch]$Physical, $ErrorAction) }

    $net = "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\PowerShell\common\network"
    . "$net\Resolve-WanAdapterName.ps1"

    function New-NetAdapter {

        param(
            [string] $Name,
            [string] $Status,
            [string] $InterfaceDescription = 'Test Adapter'
        )

        [PSCustomObject]@{
            Name = $Name
            Status = $Status
            InterfaceDescription = $InterfaceDescription
        }
    }
}

Describe 'Resolve-WanAdapterName' {

    BeforeEach {
        Mock Write-Host { }
    }

    It 'returns the name it is given, without looking at the host' {

        # Arrange
        Mock Get-WirelessNetAdapter { }

        # Act
        $name = Resolve-WanAdapterName -WanAdapterName 'Ethernet 2'

        # Assert
        $name | Should -Be 'Ethernet 2'
        Should -Invoke Get-WirelessNetAdapter -Times 0
    }

    It 'returns the Up wireless adapter when none is given, and says which' {

        # Arrange
        Mock Get-WirelessNetAdapter {
            New-NetAdapter `
                -Name 'WiFi' `
                -Status 'Up' `
                -InterfaceDescription 'Killer Wi-Fi 7'
        }

        $expectedNotice = "WAN adapter auto-detected for the ICS checks: 'WiFi' (Killer Wi-Fi 7)."

        # Act
        $name = Resolve-WanAdapterName

        # Assert
        $name | Should -Be 'WiFi'

        Should -Invoke Write-Host `
            -Times 1 `
            -Exactly `
            -ParameterFilter { $Object -eq $expectedNotice }
    }

    It 'passes over a wireless adapter that is not Up' {

        # Arrange
        Mock Get-WirelessNetAdapter {

            New-NetAdapter `
                -Name 'WiFi' `
                -Status 'Disconnected'

            New-NetAdapter `
                -Name 'WiFi 2' `
                -Status 'Up'
        }

        # Act
        $name = Resolve-WanAdapterName

        # Assert
        $name | Should -Be 'WiFi 2'
    }

    # An Ethernet-WAN host has no wireless adapter to find; the operator gets
    # the candidates and the parameter to name one with.
    It 'returns nothing and lists the physical adapters when no wireless adapter is Up' {

        # Arrange
        Mock Get-WirelessNetAdapter { }

        Mock Get-NetAdapter {

            New-NetAdapter `
                -Name 'WiFi' `
                -Status 'Disconnected'

            New-NetAdapter `
                -Name 'Ethernet' `
                -Status 'Up'
        }

        # Act
        $name = Resolve-WanAdapterName

        # Assert
        $name | Should -BeNullOrEmpty

        Should -Invoke Write-Host `
            -Times 1 `
            -Exactly `
            -ParameterFilter { $Object -eq 'Physical adapters present: Ethernet [Up], WiFi [Disconnected]' }

        Should -Invoke Write-Host `
            -Times 1 `
            -Exactly `
            -ParameterFilter { $Object -eq "Re-run with -WanAdapterName '<your internet-facing connection>'." }
    }
}
