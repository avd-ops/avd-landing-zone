// =====================================================================
// Deployment portal, published into your own subscription (optional).
// Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
//
// The portal (site/portal) is a static page. By default operators use the copy on GitHub Pages;
// this template is for a copy in their own subscription (decision 0017). It creates
// rg-<prefix>-<env>-portal holding one of:
//   StaticWebApp  an Azure Static Web Apps site on the Free plan ($0); sign-in is optional
//   Storage       a StorageV2 account whose static website serves the files (cents a month)
// Nothing in the landing zone changes. Deployed, filled and removed by
// scripts/ops/Publish-AvdPortal.ps1 (-Remove deletes the resource group).
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

@description('Region of the resource group and, for Storage, of the account: normally the landing zone\'s.')
param location string = deployment().location

@allowed([
  'StaticWebApp'
  'Storage'
])
param hosting string = 'StaticWebApp'

@description('Static Web Apps region. The Free plan is offered only in these.')
@allowed([
  'centralus'
  'eastus2'
  'westus2'
  'westeurope'
  'eastasia'
])
param staticWebAppLocation string = 'centralus'

@description('Storage only: who uploads the files (the Cloud Shell user). Gets Storage Blob Data Contributor on the account.')
param uploaderObjectId string = ''

@allowed([
  'User'
  'ServicePrincipal'
])
param uploaderPrincipalType string = 'User'

var cleanPrefix = toLower(replace(namePrefix, '-', ''))
var baseName = '${cleanPrefix}-${environmentName}-portal'
var tags = {
  workload: 'avd'
  environment: environmentName
  managedBy: 'bicep'
  landingZone: 'avd-cloud-native'
  purpose: 'portal'
}

resource rgPortal 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${baseName}'
  location: location
  tags: tags
}

module portalHost 'host.bicep' = {
  name: 'avdlz-portal-host'
  scope: rgPortal
  params: {
    hosting: hosting
    location: location
    staticWebAppLocation: staticWebAppLocation
    staticWebAppName: 'stapp-${baseName}'
    storageAccountName: 'st${cleanPrefix}${environmentName}web${substring(uniqueString(subscription().id, baseName), 0, 6)}'
    uploaderObjectId: uploaderObjectId
    uploaderPrincipalType: uploaderPrincipalType
    tags: tags
  }
}

output resourceGroupName string = rgPortal.name
output hosting string = hosting
output resourceName string = portalHost.outputs.resourceName
output portalUrl string = portalHost.outputs.portalUrl
