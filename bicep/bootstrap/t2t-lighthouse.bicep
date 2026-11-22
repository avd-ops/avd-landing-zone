// =====================================================================
// Lab topology — Azure Lighthouse T2T delegation
// Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
//
// Deployed at SUBSCRIPTION scope in the secondary Entra tenant (t2t-lab) to
// delegate access to the primary lab tenant (avd-ops ADR 0019).
// =====================================================================

targetScope = 'subscription'

@description('Display name of the Azure Lighthouse registration definition.')
param registrationName string = 'avd-ops-t2t-lab'

@description('Description of the Azure Lighthouse delegation.')
param registrationDescription string = 'Cross-tenant lab delegation for AVD T2T and Managed Services validation.'

@description('Primary lab Microsoft Entra ID tenant GUID granted access.')
param managingTenantId string

@description('Array of { principalId, principalIdDisplayName, roleDefinitionId } authorizations.')
@minLength(1)
param authorizations array

var definitionGuid = guid(subscription().subscriptionId, managingTenantId, registrationName)
var assignmentGuid = guid(subscription().subscriptionId, managingTenantId, registrationName, 'assignment')

resource registrationDefinition 'Microsoft.ManagedServices/registrationDefinitions@2022-10-01' = {
  name: definitionGuid
  properties: {
    registrationDefinitionName: registrationName
    description: registrationDescription
    managedByTenantId: managingTenantId
    authorizations: authorizations
  }
}

resource registrationAssignment 'Microsoft.ManagedServices/registrationAssignments@2022-10-01' = {
  name: assignmentGuid
  properties: {
    registrationDefinitionId: registrationDefinition.id
  }
}

output registrationDefinitionId string = registrationDefinition.id
output registrationAssignmentId string = registrationAssignment.id
