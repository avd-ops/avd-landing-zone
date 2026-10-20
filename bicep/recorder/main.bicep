// =====================================================================
// Run store for the run recorder (build/specs/run-recorder-spec.md section 6.3)
// Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
//
// Durable log storage for one subscription, set up once by
// scripts/ops/Initialize-AvdRunStore.ps1 and reused by every recorded run.
// Its own resource group, outside every landing zone, so a landing zone's
// cleanup never touches it. Nothing here deletes data: the lifecycle rule
// only moves run folders to cheaper tiers (spec R9).
//
// Deployed at SUBSCRIPTION scope. Not part of main.bicep.
// =====================================================================

targetScope = 'subscription'

metadata name = 'AVD landing zone run store'
metadata description = 'Storage account for recorded runs, with Entra-only access and tiering that never deletes.'

@description('Region for the run store.')
param location string = deployment().location

@description('Resource group for the run store, independent of any landing zone name prefix.')
param resourceGroupName string = 'avdlz-runs-rg'

@description('Storage account name (Initialize-AvdRunStore.ps1 derives it from the subscription).')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('Object ID of the operator who records runs: Storage Blob Data Contributor on this account only.')
param operatorPrincipalId string

@description('Principal type of the operator.')
@allowed([
  'User'
  'Group'
  'ServicePrincipal'
])
param operatorPrincipalType string = 'User'

@description('What teardown does with a run folder by default: Keep (default), Ask or Delete (only after a verified copy).')
@allowed([
  'Keep'
  'Ask'
  'Delete'
])
param teardownLogs string = 'Keep'

@description('The operator\'s private companion repository (owner/repo) for copies, or empty.')
param privateRepo string = ''

@description('Send the subscription Activity Log to the run store, so it outlives the 90 days Azure keeps it.')
param exportActivityLog bool = true

@description('Extra tags merged onto the resource group and the storage account.')
param tags object = {}

var storeTags = union(tags, {
  'avdlz-component': 'recorder'
  'avdlz-teardown-logs': teardownLogs
  'avdlz-private-repo': empty(privateRepo) ? 'none' : privateRepo
})

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: storeTags
}

module store 'store.bicep' = {
  name: 'avdlz-runs-store'
  scope: rg
  params: {
    location: location
    storageAccountName: storageAccountName
    operatorPrincipalId: operatorPrincipalId
    operatorPrincipalType: operatorPrincipalType
    tags: storeTags
  }
}

// Activity Log categories that matter for a run: writes, deletes and their failures.
resource activityLog 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (exportActivityLog) {
  name: 'avdlz-runs-activity'
  properties: {
    storageAccountId: store.outputs.storageAccountId
    logs: [
      { category: 'Administrative', enabled: true }
      { category: 'Policy', enabled: true }
      { category: 'ResourceHealth', enabled: true }
      { category: 'ServiceHealth', enabled: true }
    ]
  }
}

output resourceGroupName string = rg.name
output storageAccountName string = store.outputs.storageAccountName
output storageAccountId string = store.outputs.storageAccountId
output blobEndpoint string = store.outputs.blobEndpoint
