// Tag-inheritance policy assignment role at subscription scope. A child module lets the role
// assignment name include the managed identity's principalId so recreating the policy assignment
// does not collide with an earlier role assignment (RoleAssignmentUpdateNotPermitted).
targetScope = 'subscription'

param tag string
param principalId string
param roleDefinitionId string

resource assignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, 'avdlz-inherit-rg-tag', tag, principalId)
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleDefinitionId
  }
}
