# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware, ServiceNow or Microsoft.
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:ScriptPath = Join-Path $script:Root 'scripts/ops/Import-AvdNetworkingOutputs.ps1'
}

Describe 'Import-AvdNetworkingOutputs.ps1' {
    It 'rejects an unexpected schema' {
        $manifest = Join-Path $TestDrive 'bad.json'
        @{ schema = 'wrong/v1'; hubVnetResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet' } |
            ConvertTo-Json | Set-Content -Path $manifest
        { & $script:ScriptPath -NetworkingOutputsPath $manifest } | Should -Throw '*Unexpected schema*'
    }

    It 'maps C31 NVA + gateway outputs to HubPeered parameters and writes ARM parameters JSON' {
        $manifest = Join-Path $TestDrive 'nva-c31.json'
        @{
            schema                           = 'avd-networking-outputs/v1'
            firewallMode                     = 'nva'
            hubVnetResourceId                = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub'
            hubFirewallPrivateIp             = '10.0.5.68'
            dnsServers                       = @('10.0.5.68')
            centralPrivateDnsZoneResourceIds = @{
                file = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub/providers/Microsoft.Network/privateDnsZones/privatelink.file.core.windows.net'
                avd  = ''
            }
            vpnGatewayResourceId             = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworkGateways/vgw-vpn'
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $manifest

        $outParams = Join-Path $TestDrive 'hub.parameters.json'
        $p = & $script:ScriptPath -NetworkingOutputsPath $manifest -OutputParametersPath $outParams

        $p.connectivityMode | Should -Be 'HubPeered'
        $p.hubFirewallPrivateIp | Should -Be '10.0.5.68'
        $p.dnsServers | Should -Contain '10.0.5.68'
        $p.createHubToSpokePeering | Should -BeFalse
        $p.centralPrivateDnsZoneResourceIds.Contains('file') | Should -BeTrue
        $p.centralPrivateDnsZoneResourceIds.Contains('avd') | Should -BeFalse
        (Test-Path $outParams) | Should -BeTrue
        $arm = Get-Content -Raw $outParams | ConvertFrom-Json
        $arm.parameters.hubFirewallPrivateIp.value | Should -Be '10.0.5.68'
    }
}
