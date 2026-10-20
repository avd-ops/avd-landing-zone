// Profile storage — Premium Azure Files for FSLogix, Entra Kerberos auth.
//
//   - kind FileStorage: Premium file shares only exist on FileStorage accounts.
//   - Entra Kerberos (AADKERB): Entra-joined session hosts get Kerberos tickets
//     for the share from Entra ID. No domain controllers, no storage keys.
//   - Shared key access disabled unless the vaulted backup tier needs it
//     (allowSharedKeyAccess), SMB hardened to 3.1.1 + Kerberos + AES-256
//     tickets, GCM channel encryption.
//   - Share-level access via RBAC on the account; reachable only over its
//     private endpoint.
//
// One-time tenant step Bicep cannot do: grant admin consent to the storage
// account's Entra app registration. See docs/deploy.md.

param location string
param tags object
param name string

@allowed([
  'Premium_LRS'
  'Premium_ZRS'
])
param skuName string
param shareName string
param shareQuotaGiB int
param privateEndpointSubnetResourceId string
param privateDnsZoneResourceId string
param logAnalyticsWorkspaceResourceId string
param usersGroupObjectId string
param adminsGroupObjectId string

@description('Allow storage account key access. Only the vaulted profile backup tier needs it; SMB stays Kerberos-only, so a key cannot mount the share.')
param allowSharedKeyAccess bool = false

var roles = {
  smbShareContributor: '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb'
  smbShareElevatedContributor: 'a7264617-510b-434b-a828-9731dc254ea7'
}

module account 'br/public:avm/res/storage/storage-account:0.33.1' = {
  name: 'storage-account'
  params: {
    name: name
    location: location
    tags: tags
    kind: 'FileStorage'
    skuName: skuName
    allowSharedKeyAccess: allowSharedKeyAccess
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
    azureFilesIdentityBasedAuthentication: {
      directoryServiceOptions: 'AADKERB'
    }
    fileServices: {
      protocolSettings: {
        smb: {
          versions: 'SMB3.1.1;'
          authenticationMethods: 'Kerberos;'
          kerberosTicketEncryption: 'AES-256;'
          // AES-128-GCM must stay allowed: with AES-256-GCM alone, Azure Files rejects an Entra
          // Kerberos SESSION_SETUP from a cloud-only user with STATUS_ACCESS_DENIED, and FSLogix
          // fails with "Access is denied". CCM stays off.
          channelEncryption: 'AES-128-GCM;AES-256-GCM;'
          multichannel: {
            enabled: true
          }
        }
      }
      shareDeleteRetentionPolicy: {
        enabled: true
        days: 14
      }
      shares: [
        {
          name: shareName
          shareQuota: shareQuotaGiB
          enabledProtocols: 'SMB'
        }
      ]
      diagnosticSettings: [
        {
          workspaceResourceId: logAnalyticsWorkspaceResourceId
        }
      ]
    }
    privateEndpoints: [
      {
        service: 'file'
        subnetResourceId: privateEndpointSubnetResourceId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: privateDnsZoneResourceId
            }
          ]
        }
      }
    ]
    roleAssignments: [
      {
        principalId: usersGroupObjectId
        principalType: 'Group'
        roleDefinitionIdOrName: roles.smbShareContributor
      }
      {
        principalId: adminsGroupObjectId
        principalType: 'Group'
        roleDefinitionIdOrName: roles.smbShareElevatedContributor
      }
    ]
    diagnosticSettings: [
      {
        workspaceResourceId: logAnalyticsWorkspaceResourceId
        metricCategories: [
          {
            category: 'Transaction'
          }
        ]
      }
    ]
  }
}

output name string = account.outputs.name
output resourceId string = account.outputs.resourceId
output profileShareUncPath string = '\\\\${account.outputs.name}.file.${environment().suffixes.storage}\\${shareName}'
