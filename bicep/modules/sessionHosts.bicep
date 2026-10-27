// Session hosts — Entra ID joined (optionally Intune enrolled), Trusted Launch,
// zone-spread, monitored by AMA, and made ready for users declaratively:
//   1. Configure-FSLogix run command (Entra Kerberos + profile container)
//   2. Register-AvdAgent run command (agent + boot loader + token)
// Both scripts live in scripts/sessionhost/ and are embedded at compile time.

param location string
param tags object
param count int
@maxLength(11)
param namePrefix string
param vmSize string
param availabilityZones int[]
param imageReference object
param encryptionAtHost bool
param subnetResourceId string
param enrollInIntune bool
param localAdminUsername string

@secure()
param localAdminPassword string

@secure()
param hostPoolRegistrationToken string

param dataCollectionRuleResourceId string
param profileShareUncPath string
param fslogixProfileSizeMiB int
param usersGroupObjectId string
param adminsGroupObjectId string
param avdServicePrincipalObjectId string

@description('Daily shutdown time (HHmm, in autoShutdownTimeZone) for these hosts; empty = none. The demo sets it: the landing zone auto shutdown covers only its own host pool (avd-second-brain decision 0017).')
param autoShutdownTime string = ''
param autoShutdownTimeZone string = 'UTC'

@description('Create the resource-group role assignments for VM sign-in and power management. Set to false on additional pool modules targeting the same resource group.')
param deployRoleAssignments bool = true

var roles = {
  vmUserLogin: 'fb879df8-f326-4884-b1cf-06f3ad86be52'
  vmAdminLogin: '1c0163c0-47e6-4577-8991-ea5c82e286e4'
  powerOnOffContributor: '40c5ff49-9181-41f8-ae61-143b0e78555e'
}

// 11-char prefix + '-' + 3-digit index = 15 chars, the Windows computer-name limit.
var vmNames = [for i in range(0, count): '${namePrefix}-${padLeft(i + 1, 3, '0')}']
var intuneMdmId = '0000000a-0000-0000-c000-000000000000'

module vm 'br/public:avm/res/compute/virtual-machine:0.22.3' = [
  for (vmName, i) in vmNames: {
    name: 'vm-${vmName}'
    params: {
      name: vmName
      location: location
      tags: tags
      vmSize: vmSize
      autoShutdownConfig: empty(autoShutdownTime) ? {} : { status: 'Enabled', dailyRecurrenceTime: autoShutdownTime, timeZone: autoShutdownTimeZone }
      osType: 'Windows'
      // AVD multi-session: Windows client licensing via the user's M365/Windows E3+ entitlement.
      licenseType: 'Windows_Client'
      availabilityZone: empty(availabilityZones) ? -1 : availabilityZones[i % length(availabilityZones)]
      imageReference: imageReference
      securityType: 'TrustedLaunch'
      secureBootEnabled: true
      vTpmEnabled: true
      encryptionAtHost: encryptionAtHost
      // Premium SSD for the OS disk: multi-session hosts page, log on and update many users at once.
      osDisk: {
        caching: 'ReadWrite'
        deleteOption: 'Delete'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
      adminUsername: localAdminUsername
      adminPassword: localAdminPassword
      nicConfigurations: [
        {
          nicSuffix: '-nic'
          deleteOption: 'Delete'
          enableAcceleratedNetworking: true
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
      extensionAadJoinConfig: {
        enabled: true
        settings: enrollInIntune
          ? {
              mdmId: intuneMdmId
            }
          : {}
      }
      extensionMonitoringAgentConfig: {
        enabled: true
        dataCollectionRuleAssociations: [
          {
            name: 'avd-insights'
            dataCollectionRuleResourceId: dataCollectionRuleResourceId
          }
        ]
      }
      extensionGuestConfigurationExtension: {
        enabled: true
      }
      // Windows 11 ships Microsoft Defender Antivirus; the IaaS antimalware
      // extension is for Windows Server only.
      extensionAntiMalwareConfig: {
        enabled: false
      }
    }
  }
]

resource sessionHost 'Microsoft.Compute/virtualMachines@2024-07-01' existing = [
  for vmName in vmNames: {
    name: vmName
  }
]

resource configureFslogix 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = [
  for (vmName, i) in vmNames: {
    parent: sessionHost[i]
    name: 'Configure-FSLogix'
    location: location
    tags: tags
    properties: {
      source: {
        script: loadTextContent('../../scripts/sessionhost/Set-FSLogixConfiguration.ps1')
      }
      parameters: [
        {
          name: 'ProfileShareUncPath'
          value: profileShareUncPath
        }
        {
          name: 'ProfileSizeMiB'
          value: string(fslogixProfileSizeMiB)
        }
        {
          name: 'LocalAdminUsername'
          value: localAdminUsername
        }
      ]
      asyncExecution: false
      treatFailureAsDeploymentFailure: true
      timeoutInSeconds: 600
    }
    dependsOn: [
      vm[i]
    ]
  }
]

resource registerAgent 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = [
  for (vmName, i) in vmNames: {
    parent: sessionHost[i]
    name: 'Register-AvdAgent'
    location: location
    tags: tags
    properties: {
      source: {
        script: loadTextContent('../../scripts/sessionhost/Register-AvdAgent.ps1')
      }
      protectedParameters: [
        {
          name: 'RegistrationToken'
          value: hostPoolRegistrationToken
        }
      ]
      asyncExecution: false
      treatFailureAsDeploymentFailure: true
      timeoutInSeconds: 1800
    }
    // Run commands on one VM execute one at a time.
    dependsOn: [
      configureFslogix[i]
    ]
  }
]

// ---------- Access to the hosts ----------
// Entra ID sign-in to the VMs requires these, in addition to the app group assignment.
resource usersLogin 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployRoleAssignments) {
  name: guid(resourceGroup().id, usersGroupObjectId, roles.vmUserLogin)
  properties: {
    principalId: usersGroupObjectId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.vmUserLogin)
  }
}

resource adminsLogin 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployRoleAssignments) {
  name: guid(resourceGroup().id, adminsGroupObjectId, roles.vmAdminLogin)
  properties: {
    principalId: adminsGroupObjectId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.vmAdminLogin)
  }
}

// Autoscale and Start VM on Connect start/stop the VMs in this resource group.
resource powerOnOff 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployRoleAssignments) {
  name: guid(resourceGroup().id, avdServicePrincipalObjectId, roles.powerOnOffContributor)
  properties: {
    principalId: avdServicePrincipalObjectId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.powerOnOffContributor)
  }
}

output names string[] = vmNames
