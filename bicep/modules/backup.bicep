// Profile backup — Recovery Services vault protecting the FSLogix share with
// daily backups (build/specs/recovery-spec.md section 4).
//   Snapshot (default): share snapshots kept in the storage account. They go
//     with the share: a deleted share or account loses them.
//   Vaulted (opt-in, tier R1): the last snapshot of each day is also copied
//     into the vault, geo-redundant with Cross Region Restore, so a copy
//     survives the share, the account and the region. Microsoft's support
//     matrix says the source account must allow storage account key access
//     for this tier; storage.bicep follows the same parameter.
//
// Note: registering a storage account with Azure Backup places a delete lock
// (AzureBackupProtectionLock) on it. Stop protection before tearing down.

param location string
param tags object
param vaultName string
param storageAccountResourceId string
param shareName string
param retentionDays int

@description('Snapshot: share snapshots only (default). Vaulted: also an offsite copy in the vault, geo-redundant with Cross Region Restore (recovery tier R1).')
@allowed([
  'Snapshot'
  'Vaulted'
])
param profileBackupTier string = 'Snapshot'

@description('Vaulted tier only: days each daily snapshot stays on the share before only the vault copy remains (1 to 30).')
@minValue(1)
@maxValue(30)
param vaultedSnapshotRetentionDays int = 7
param logAnalyticsWorkspaceResourceId string

var storageAccountName = last(split(storageAccountResourceId, '/'))
var backupTime = '2025-01-01T02:00:00Z'
var vaulted = profileBackupTier == 'Vaulted'
var dailyRetention = {
  retentionPolicyType: 'LongTermRetentionPolicy'
  dailySchedule: {
    retentionTimes: [
      backupTime
    ]
    retentionDuration: {
      count: retentionDays
      durationType: 'Days'
    }
  }
}

resource vault 'Microsoft.RecoveryServices/vaults@2024-04-01' = {
  name: vaultName
  location: location
  tags: tags
  sku: {
    name: 'RS0'
    tier: 'Standard'
  }
  properties: union({
    publicNetworkAccess: 'Disabled'
    securitySettings: {
      softDeleteSettings: {
        softDeleteState: 'Enabled'
        softDeleteRetentionPeriodInDays: 14
      }
      // Blocks operations that would shorten retention or delete recovery points
      // early. 'Unlocked' can still be reverted; lock it in the portal once your
      // retention policy is final (locking is irreversible).
      immutabilitySettings: {
        state: 'Unlocked'
      }
    }
  }, vaulted ? {
    // Only for the vaulted tier, so the default deployment's vault is unchanged. A vault's
    // redundancy can't change once an item is protected in it: switching an existing landing
    // zone to Vaulted may need a new vault (spec section 12, U7).
    redundancySettings: {
      standardTierStorageRedundancy: 'GeoRedundant'
      crossRegionRestore: 'Enabled'
    }
  } : {})
}

resource policy 'Microsoft.RecoveryServices/vaults/backupPolicies@2024-04-01' = {
  parent: vault
  name: vaulted ? 'fslogix-daily-vaulted' : 'fslogix-daily'
  properties: union({
    backupManagementType: 'AzureStorage'
    workLoadType: 'AzureFileShare'
    timeZone: 'UTC'
    schedulePolicy: {
      schedulePolicyType: 'SimpleSchedulePolicy'
      scheduleRunFrequency: 'Daily'
      scheduleRunTimes: [
        backupTime
      ]
    }
  }, vaulted ? {
    vaultRetentionPolicy: {
      snapshotRetentionInDays: vaultedSnapshotRetentionDays
      vaultRetention: dailyRetention
    }
  } : {
    retentionPolicy: dailyRetention
  })
}

// The 'Azure' backup fabric is built in to every vault and is not a deployable
// type, so the container is addressed by its full name rather than via parent.
#disable-next-line use-parent-property
resource container 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers@2024-04-01' = {
  name: '${vault.name}/Azure/storagecontainer;Storage;${resourceGroup().name};${storageAccountName}'
  properties: {
    backupManagementType: 'AzureStorage'
    containerType: 'StorageContainer'
    sourceResourceId: storageAccountResourceId
  }
}

resource protectedShare 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems@2024-04-01' = {
  parent: container
  name: 'AzureFileShare;${shareName}'
  properties: {
    protectedItemType: 'AzureFileShareProtectedItem'
    sourceResourceId: storageAccountResourceId
    policyId: policy.id
  }
}

resource vaultDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: vault
  properties: {
    workspaceId: logAnalyticsWorkspaceResourceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

output vaultResourceId string = vault.id
output profileBackupTier string = profileBackupTier
