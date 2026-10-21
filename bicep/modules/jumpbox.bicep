// Operator jumpbox (build/decisions/0019-jumpbox-bastion-developer.md): a small Linux or Windows Server
// VM in the landing zone's spoke with Cloud Shell's toolchain (Linux: scripts/jumpbox/cloud-init.yaml at
// first boot; Windows: scripts/jumpbox/Install-JumpboxTools.ps1 as a Run Command when it is created),
// reached only through Azure Bastion Developer in the browser (SSH or RDP). No public IP.
//
// Sign-in: Bastion Developer offers no Microsoft Entra sign-in (that needs Basic or higher, billed by
// the hour), so the OS account is local. Its password is random, set at creation and stored nowhere;
// scripts/ops/Connect-AvdJumpbox.ps1 sets a new one-time password through the management plane each
// time an operator connects. Azure and Graph sign-ins on the box are the operator's own (device code).
// The VM's managed identity has no roles: the box holds no standing rights of its own.
//
// Never leave the meter running (avd-second-brain decision 0017): the VM stops daily on its own
// schedule unless keepRunningUntil is set, which is then recorded on the VM's avdlz-keep-running-until tag.
//
// An existing VM (vmExists, set by deploy.sh) is never re-sent: Azure refuses a change to the custom
// data and admin password of a VM that exists. Its daily stop and tags are separate resources here,
// so a redeploy still updates them.

param location string
param tags object
param vmName string
param vmSize string

@allowed([
  'Linux'
  'Windows'
])
param osType string = 'Linux'
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

@description('The VM already exists: update only its daily stop and tags.')
param vmExists bool = false

var roles = {
  reader: 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
  virtualMachineContributor: '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'
}
var keepRunning = !empty(keepRunningUntil)
var windows = osType == 'Windows'
var images = {
  Linux: {
    publisher: 'Canonical'
    offer: 'ubuntu-24_04-lts'
    sku: 'server'
    version: 'latest'
  }
  // Windows Server 2025 Azure Edition: Generation 2, Trusted Launch, patched by the platform.
  Windows: {
    publisher: 'MicrosoftWindowsServer'
    offer: 'WindowsServer'
    sku: '2025-datacenter-azure-edition'
    version: 'latest'
  }
}
var vmTags = union(tags, { purpose: 'jumpbox' }, keepRunning ? { 'avdlz-keep-running-until': keepRunningUntil } : {})

module vm 'br/public:avm/res/compute/virtual-machine:0.22.3' = if (!vmExists) {
  name: 'vm-${vmName}'
  params: {
    name: vmName
    location: location
    tags: vmTags
    vmSize: vmSize
    osType: osType
    availabilityZone: -1
    imageReference: images[osType]
    securityType: 'TrustedLaunch'
    secureBootEnabled: true
    vTpmEnabled: true
    encryptionAtHost: encryptionAtHost
    // Standard SSD: a workstation for scripts, not a session host. E4 for Linux, E10 for Windows.
    osDisk: {
      caching: 'ReadWrite'
      deleteOption: 'Delete'
      diskSizeGB: windows ? 128 : 32
      managedDisk: {
        storageAccountType: 'StandardSSD_LRS'
      }
    }
    adminUsername: adminUsername
    adminPassword: adminPassword
    disablePasswordAuthentication: false
    customData: windows ? '' : loadTextContent('../../scripts/jumpbox/cloud-init.yaml')
    patchMode: windows ? 'AutomaticByPlatform' : ''
    // With no maintenance configuration attached, the platform must not wait for a customer schedule.
    bypassPlatformSafetyChecksOnUserSchedule: false
    // Windows computer names stop at 15 characters; vm-<prefix>-<env>-jumpbox doesn't fit.
    computerName: windows ? 'jumpbox' : vmName
    // Microsoft Defender Antivirus is built into Windows Server 2025: no IaaSAntimalware extension.
    extensionAntiMalwareConfig: {
      enabled: false
    }
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

resource vmRef 'Microsoft.Compute/virtualMachines@2024-07-01' existing = {
  name: vmName
}

// Windows first boot: the toolchain, once, when the VM is created (asynchronous: the deployment doesn't
// wait; C:\avdlz\jumpbox.log ends with 'ready'). Never re-sent with an existing VM.
resource windowsTools 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = if (windows && !vmExists) {
  parent: vmRef
  name: 'avdlz-jumpbox-tools'
  location: location
  tags: tags
  properties: {
    source: {
      script: loadTextContent('../../scripts/jumpbox/Install-JumpboxTools.ps1')
    }
    asyncExecution: true
    timeoutInSeconds: 3600
  }
  dependsOn: [
    vm
  ]
}

// The daily stop, always present: Disabled while kept running, so a redeploy with
// --jumpbox-keep-running turns off a stop that exists (an absent schedule would leave it on).
resource dailyStop 'Microsoft.DevTestLab/schedules@2018-09-15' = {
  name: 'shutdown-computevm-${vmName}'
  location: location
  tags: tags
  properties: {
    status: keepRunning ? 'Disabled' : 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: {
      time: autoShutdownTime
    }
    timeZoneId: autoShutdownTimeZone
    notificationSettings: {
      status: 'Disabled'
      timeInMinutes: 30
    }
    targetResourceId: vmRef.id
  }
  dependsOn: [
    vm
  ]
}

// On an existing VM the module doesn't run, so its tags (avdlz-keep-running-until) are set here.
resource existingVmTags 'Microsoft.Resources/tags@2024-03-01' = if (vmExists) {
  name: 'default'
  scope: vmRef
  properties: {
    tags: vmTags
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
output resourceId string = vmRef.id
