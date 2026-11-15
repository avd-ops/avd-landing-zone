// Azure Bastion Developer (build/decisions/0019-jumpbox-bastion-developer.md): browser RDP/SSH to the
// jumpbox at no charge. Facts from Microsoft Learn (bastion-sku-comparison, configuration-settings):
// no AzureBastionSubnet and no public IP; a shared pool, one VM connection at a time; only VMs in this
// VNet (no peering); only in the regions listed there (Get-AvdBastionDeveloperRegion); no Entra
// sign-in, custom ports, native client or shareable links. Deployed in the VNet's resource group.

param location string
param tags object
param name string
param vnetResourceId string

@description('Entra group of AVD operators: Reader on this Bastion, which a connection needs.')
param adminsGroupObjectId string

var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'

resource bastion 'Microsoft.Network/bastionHosts@2024-07-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: 'Developer'
  }
  properties: {
    virtualNetwork: {
      id: vnetResourceId
    }
  }
}

resource adminsReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(bastion.id, adminsGroupObjectId, readerRoleId)
  scope: bastion
  properties: {
    principalId: adminsGroupObjectId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
  }
}

output resourceId string = bastion.id
