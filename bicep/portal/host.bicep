// The host for the deployment portal: a Static Web Apps site (Free) or a storage account for its
// static website. Deployed by main.bicep in this folder; see there.

param hosting string
param location string
param staticWebAppLocation string
param staticWebAppName string
param storageAccountName string
param uploaderObjectId string
param uploaderPrincipalType string
param tags object

// Storage Blob Data Contributor: the uploader writes the files into $web with its own sign-in (no account keys).
var blobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

resource staticSite 'Microsoft.Web/staticSites@2023-12-01' = if (hosting == 'StaticWebApp') {
  name: staticWebAppName
  location: staticWebAppLocation
  tags: tags
  sku: {
    name: 'Free'
    tier: 'Free'
  }
  properties: {
    // Files are uploaded from Cloud Shell with a deployment token, not from a linked repository.
    stagingEnvironmentPolicy: 'Disabled'
    allowConfigFileUpdates: true
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = if (hosting == 'Storage') {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    // The static website endpoint serves $web anonymously whatever this says; blobs stay private.
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
  }
}

resource uploader 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (hosting == 'Storage' && !empty(uploaderObjectId)) {
  name: guid(storageAccountName, uploaderObjectId, blobDataContributorRoleId)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobDataContributorRoleId)
    principalId: uploaderObjectId
    principalType: uploaderPrincipalType
  }
}

output resourceName string = hosting == 'StaticWebApp' ? staticWebAppName : storageAccountName
// Storage: the static website endpoint, served once the script turns the website on.
output portalUrl string = hosting == 'StaticWebApp' ? 'https://${staticSite!.properties.defaultHostname}/' : storage!.properties.primaryEndpoints.web
