// Registers additional host pools' session hosts (created and FSLogix-configured
// by sessionHosts.bicep) to their respective host pools without duplicating the
// AVM virtual-machine module in the compiled subscription template.

param location string
param tags object
param count int
@maxLength(11)
param namePrefix string

@secure()
param hostPoolRegistrationToken string

var vmNames = [for i in range(0, count): '${namePrefix}-${padLeft(i + 1, 3, '0')}']

resource sessionHost 'Microsoft.Compute/virtualMachines@2024-07-01' existing = [
  for vmName in vmNames: {
    name: vmName
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
  }
]

output names string[] = vmNames
