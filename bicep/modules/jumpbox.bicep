// Operator jumpbox (build/decisions/0018-jumpbox-bastion-developer.md): a small Linux VM in the
// landing zone's spoke with Cloud Shell's toolchain (scripts/jumpbox/cloud-init.yaml), reached only
// through Azure Bastion Developer in the browser. No public IP.
//
// Sign-in: Bastion Developer offers no Microsoft Entra sign-in (that needs Basic or higher, billed by
// the hour), so the OS account is local. Its password is random, set at creation and stored nowhere;
// scripts/ops/Connect-AvdJumpbox.ps1 sets a new one-time password through the management plane each
// time an operator connects. Azure and Graph sign-ins on the box are the operator's own (device code).
// The VM's managed identity has no roles: the box holds no standing rights of its own.
//
// Never leave the meter running (avd-second-brain decision 0017): the VM stops daily on its own
// schedule unless keepRunningUntil is set, which is then recorded on the VM's avdlz-keep-running-until tag.

param location string
param tags object
param vmName string
param vmSize string
param subnetResourceId string
param encryptionAtHost bool
param adminUsername string

@secure()
param adminPassword string

@description('Daily stop (HHmm, in autoShutdownTimeZone). Ignored when keepRunningUntil is set.')
param autoShutdownTime string
param autoShutdownTimeZone string

@description('Opt out of the daily stop until this UTC time (yyyy-MM-ddTHH:mmZ). Empty: the daily stop applies.')
param keepRunningUntil string = ''

@description('Entra group of AVD operators: Reader and Virtual Machine Contributor on this resource group (connect through Bastion, start, stop, set the one-time password).')
param adminsGroupObjectId string

var roles = {
  reader: 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
  virtualMachineContributor: '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'
}
var keepRunning = !empty(keepRunningUntil)
var vmTags = union(tags, { purpose: 'jumpbox' }, keepRunning ? { 'avdlz-keep-running-until': keepRunningUntil } : {})

module vm 'br/public:avm/res/compute/virtual-machine:0.22.3' = {
  name: 'vm-${vmName}'
  params: {
    name: vmName
    location: location
    tags: vmTags
    vmSize: vmSize
    osType: 'Linux'
    availabilityZone: -1
    imageReference: {
      publisher: 'Canonical'
      offer: 'ubuntu-24_04-lts'
      sku: 'server'
      version: 'latest'
    }
    securityType: 'TrustedLaunch'
    secureBootEnabled: true
    vTpmEnabled: true
    encryptionAtHost: encryptionAtHost
    // Standard SSD: a workstation for scripts, not a session host.
    osDisk: {
      caching: 'ReadWrite'
      deleteOption: 'Delete'
      diskSizeGB: 32
      managedDisk: {
        storageAccountType: 'StandardSSD_LRS'
      }
    }
    adminUsername: adminUsername
    adminPassword: adminPassword
    disablePasswordAuthentication: false
    customData: loadTextContent('../../scripts/jumpbox/cloud-init.yaml')
    autoShutdownConfig: keepRunning ? {} : { status: 'Enabled', dailyRecurrenceTime: autoShutdownTime, timeZone: autoShutdownTimeZone }
    nicConfigurations: [
      {
        nicSuffix: '-nic'
        deleteOption: 'Delete'
        ipConfigurations: [
          {
            name: 'ipconfig1'
            subnetResourceId: subnetResourceId
          }
        ]
      }
    ]
    managedIdentities: {
      systemAssigned: true
    }
    bootDiagnostics: true
  }
}

// Bastion needs Reader on the VM and its NIC; starting, stopping and setting the password need
// Virtual Machine Contributor. Scoped to this resource group, which holds only the jumpbox.
resource adminsReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, adminsGroupObjectId, roles.reader)
  properties: {
    principalId: adminsGroupObjectId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.reader)
  }
}

resource adminsVmContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, adminsGroupObjectId, roles.virtualMachineContributor)
  properties: {
    principalId: adminsGroupObjectId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.virtualMachineContributor)
  }
}

output name string = vmName
output resourceId string = vm.outputs.resourceId
