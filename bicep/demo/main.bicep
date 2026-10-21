// =====================================================================
// Demo host pool — deployed INTO an existing landing zone.
// Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
//
// Creates rg-<prefix>-<env>-demo holding a pooled host pool, desktop app
// group, workspace and session host(s), wired to the landing zone's spoke,
// profile share, Log Analytics and private DNS. It reuses the landing
// zone's own controlPlane and sessionHosts modules, so a demo host is built
// exactly like a production host.
//
// Normally deployed by scripts/ops/Deploy-AvdDemo.ps1, which discovers every
// landing-zone input below. Removed by scripts/ops/Remove-AvdDemo.ps1.
// =====================================================================

targetScope = 'subscription'

@description('Landing zone name prefix (same value used for the landing zone).')
@minLength(2)
@maxLength(8)
param namePrefix string

@description('Landing zone environment.')
@allowed([
  'dev'
  'test'
  'prod'
])
param environmentName string

param location string = deployment().location

// ---------- Landing zone inputs (discovered by Deploy-AvdDemo.ps1) ----------
param sessionHostSubnetResourceId string
param privateEndpointSubnetResourceId string

@description('Private DNS zone for privatelink.wvd.microsoft.com. Empty when AVD Private Link is off.')
param avdPrivateDnsZoneResourceId string = ''
param logAnalyticsWorkspaceResourceId string
param dataCollectionRuleResourceId string
param profileShareUncPath string
param usersGroupObjectId string
param adminsGroupObjectId string
param avdServicePrincipalObjectId string

// ---------- Demo shape ----------
@minValue(1)
@maxValue(5)
param sessionHostCount int = 1
@description('Daily shutdown of the demo hosts (HHmm, Central time); empty keeps them running, an explicit opt-in (avd-second-brain decision 0017). The landing zone auto shutdown does not cover the demo host pool.')
param autoShutdownTime string = '2000'
param sessionHostVmSize string = 'Standard_E4as_v5'
param availabilityZones int[] = []
param enrollInIntune bool = true
param encryptionAtHost bool = true
param sessionHostImage object = {
  publisher: 'MicrosoftWindowsDesktop'
  offer: 'office-365'
  sku: 'win11-24h2-avd-m365'
  version: 'latest'
}
param localAdminUsername string = 'avdbreakglass'

@secure()
@minLength(14)
param localAdminPassword string

param rdpProperties string = 'enablerdsaadauth:i:1;targetisaadjoined:i:1;drivestoredirect:s:;usbdevicestoredirect:s:;redirectcomports:i:0;redirectsmartcards:i:1;redirectprinters:i:1;redirectclipboard:i:1;redirectwebauthn:i:1;audiomode:i:0;audiocapturemode:i:1;camerastoredirect:s:*;use multimon:i:1'

var cleanPrefix = toLower(replace(namePrefix, '-', ''))
var baseName = '${cleanPrefix}-${environmentName}-demo'
var tags = {
  workload: 'avd'
  environment: environmentName
  managedBy: 'bicep'
  landingZone: 'avd-cloud-native'
  purpose: 'demo'
}

resource rgDemo 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${baseName}'
  location: location
  tags: tags
}

module controlPlane '../modules/controlPlane.bicep' = {
  name: 'avdlz-demo-control-plane'
  scope: rgDemo
  params: {
    location: location
    tags: tags
    hostPoolName: 'vdpool-${baseName}'
    appGroupName: 'vdag-${baseName}-desktop'
    workspaceName: 'vdws-${baseName}'
    scalingPlanName: 'vdscaling-${baseName}'
    deployScalingPlan: false
    maxSessionLimit: 4
    rdpProperties: rdpProperties
    validationEnvironment: true
    enableAvdPrivateLink: !empty(avdPrivateDnsZoneResourceId)
    privateEndpointSubnetResourceId: privateEndpointSubnetResourceId
    avdPrivateDnsZoneResourceId: avdPrivateDnsZoneResourceId
    // Keep the private endpoint in the demo RG so removing the RG removes it.
    privateEndpointResourceGroupResourceId: rgDemo.id
    scalingTimeZone: 'UTC'
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    usersGroupObjectId: usersGroupObjectId
    avdServicePrincipalObjectId: avdServicePrincipalObjectId
  }
}

module sessionHosts '../modules/sessionHosts.bicep' = {
  name: 'avdlz-demo-session-hosts'
  scope: rgDemo
  params: {
    location: location
    tags: tags
    count: sessionHostCount
    namePrefix: take('${cleanPrefix}${take(environmentName, 1)}demo', 11)
    vmSize: sessionHostVmSize
    availabilityZones: availabilityZones
    imageReference: sessionHostImage
    encryptionAtHost: encryptionAtHost
    subnetResourceId: sessionHostSubnetResourceId
    enrollInIntune: enrollInIntune
    localAdminUsername: localAdminUsername
    localAdminPassword: localAdminPassword
    hostPoolRegistrationToken: controlPlane.outputs.registrationToken
    dataCollectionRuleResourceId: dataCollectionRuleResourceId
    profileShareUncPath: profileShareUncPath
    fslogixProfileSizeMiB: 30720
    autoShutdownTime: autoShutdownTime
    autoShutdownTimeZone: 'Central Standard Time'
    usersGroupObjectId: usersGroupObjectId
    adminsGroupObjectId: adminsGroupObjectId
    avdServicePrincipalObjectId: avdServicePrincipalObjectId
  }
}

output resourceGroupName string = rgDemo.name
output hostPoolResourceId string = controlPlane.outputs.hostPoolResourceId
output hostPoolName string = controlPlane.outputs.hostPoolName
output appGroupResourceId string = controlPlane.outputs.appGroupResourceId
output workspaceResourceId string = controlPlane.outputs.workspaceResourceId
output sessionHostNames string[] = sessionHosts.outputs.names
