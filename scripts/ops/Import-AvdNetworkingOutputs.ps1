# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware, ServiceNow or Microsoft.
#requires -Version 5.1
<#
.SYNOPSIS
Imports C31 (avd-networking-outputs/v1) into HubPeered Bicep parameters for avd-landing-zone / avd-azure.

.DESCRIPTION
Reads networking-outputs.json emitted by avd-networking or avd-current-state (Export-AvdNetworkingOutputs.ps1)
and maps hubVnetResourceId, hubFirewallPrivateIp (Azure Firewall or 3rd-party NVA), dnsServers, and
centralPrivateDnsZoneResourceIds into avd-landing-zone HubPeered parameters.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$NetworkingOutputsPath,

    [switch]$CreateHubToSpokePeering,

    [string]$OutputParametersPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$raw = Get-Content -Raw -Path $NetworkingOutputsPath | ConvertFrom-Json
if ($raw.schema -ne 'avd-networking-outputs/v1') {
    throw "Unexpected schema '$($raw.schema)'; expected 'avd-networking-outputs/v1'."
}
if ([string]::IsNullOrWhiteSpace([string]$raw.hubVnetResourceId)) {
    throw 'networking-outputs.json is missing hubVnetResourceId.'
}

$zones = [ordered]@{}
if ($null -ne $raw.centralPrivateDnsZoneResourceIds) {
    foreach ($prop in $raw.centralPrivateDnsZoneResourceIds.PSObject.Properties) {
        $val = [string]$prop.Value
        if (-not [string]::IsNullOrWhiteSpace($val)) {
            $zones[$prop.Name] = $val
        }
    }
}

$params = [ordered]@{
    connectivityMode                 = 'HubPeered'
    hubVnetResourceId                = [string]$raw.hubVnetResourceId
    createHubToSpokePeering          = [bool]$CreateHubToSpokePeering
    hubFirewallPrivateIp             = [string]($raw.hubFirewallPrivateIp ?? '')
    dnsServers                       = @($raw.dnsServers | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    centralPrivateDnsZoneResourceIds = $zones
}

if (-not [string]::IsNullOrWhiteSpace($OutputParametersPath)) {
    $armParams = [ordered]@{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = [ordered]@{}
    }
    foreach ($k in $params.Keys) {
        $armParams.parameters[$k] = @{ value = $params[$k] }
    }
    $armParams | ConvertTo-Json -Depth 8 | Set-Content -Path $OutputParametersPath -Encoding UTF8
}

$params
