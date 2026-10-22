// Deadline teardown for sandbox batches (decision 0021; main.bicep in this folder): an Azure
// Automation account beside the run store, with the runbook scripts/automation/Invoke-AvdSandboxDeadline.ps1.
// Invoke-AvdSandboxBatch.ps1 links a one-time schedule to it before a group starts, so a group
// whose runner died is still torn down at its deadline. Basic SKU: jobs bill past the 500 free
// minutes a month per subscription; each firing takes a few minutes.
// Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.

param location string
param tags object
param storageAccountName string

@description('Where Automation downloads the runbook from: its raw URL at a commit SHA or a v* tag (Initialize-AvdRunStore.ps1 pins it).')
param runbookUri string

// Built-in role: Storage Blob Data Contributor (public, well-known ID).
var blobDataContributor = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

resource automation 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: 'aa-avdlz-runs'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Basic'
    }
    disableLocalAuth: true
    encryption: {
      keySource: 'Microsoft.Automation'
    }
  }
}

resource runbook 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: automation
  name: 'Invoke-AvdSandboxDeadline'
  location: location
  tags: tags
  properties: {
    // Windows PowerShell 5.1, no modules: ARM and Blob REST with the managed identity's tokens.
    runbookType: 'PowerShell'
    description: 'Tears down a sandbox batch group whose runner is gone, at its deadline (decision 0021).'
    logProgress: false
    logVerbose: false
    publishContentLink: {
      uri: runbookUri
    }
  }
}

resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource blob 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' existing = {
  parent: sa
  name: 'default'
}

resource records 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' existing = {
  parent: blob
  name: 'records'
}

// Reads a group's results and writes its deadline record: the records container only.
resource recordsAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(records.id, automation.id, blobDataContributor)
  scope: records
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobDataContributor)
    principalId: automation.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output automationAccountName string = automation.name
output principalId string = automation.identity.principalId
