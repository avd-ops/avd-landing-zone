// Key Vault — holds the session hosts' break-glass local admin credential.
// RBAC-authorized, purge-protected, reachable only over its private endpoint.

param location string
param tags object
param name string
param privateEndpointSubnetResourceId string
param privateDnsZoneResourceId string
param logAnalyticsWorkspaceResourceId string
param adminsGroupObjectId string
param localAdminUsername string

@secure()
param localAdminPassword string

param deployTripwires bool = false

@secure()
param tripwireSecretName string = ''

var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'
var baseSecrets = [
  {
    name: 'sessionhost-localadmin-username'
    value: localAdminUsername
  }
  {
    name: 'sessionhost-localadmin-password'
    value: localAdminPassword
    contentType: 'Break-glass local administrator for AVD session hosts'
  }
]
var tripwireSecrets = deployTripwires && !empty(tripwireSecretName)
  ? [
      {
        name: tripwireSecretName
        value: guid(subscription().id, resourceGroup().id, name, 'tripwire')
        contentType: 'Canary credential — do not use'
      }
    ]
  : []

module vault 'br/public:avm/res/key-vault/vault:0.14.2' = {
  name: 'key-vault'
  params: {
    name: name
    location: location
    tags: tags
    sku: 'standard'
    enableRbacAuthorization: true
    enablePurgeProtection: true
    softDeleteRetentionInDays: 90
    enableVaultForDeployment: false
    enableVaultForDiskEncryption: false
    enableVaultForTemplateDeployment: false
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
    privateEndpoints: [
      {
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
    secrets: concat(baseSecrets, tripwireSecrets)
    roleAssignments: [
      {
        principalId: adminsGroupObjectId
        principalType: 'Group'
        roleDefinitionIdOrName: keyVaultSecretsUserRoleId
      }
    ]
    diagnosticSettings: [
      {
        workspaceResourceId: logAnalyticsWorkspaceResourceId
        logCategoriesAndGroups: [
          {
            categoryGroup: 'allLogs'
          }
        ]
      }
    ]
  }
}

output name string = vault.outputs.name
output resourceId string = vault.outputs.resourceId
