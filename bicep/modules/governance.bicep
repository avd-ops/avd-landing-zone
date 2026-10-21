// Governance — subscription-level guardrails for a dedicated AVD landing zone
// subscription: Azure Policy, Defender for Cloud, a budget, and the activity
// log shipped to Log Analytics.
//
// If your subscription already sits under an Azure Landing Zones management
// group hierarchy that assigns these, set enablePolicyGuardrails /
// enableDefenderForCloud to false and let the platform own them.

targetScope = 'subscription'

param location string
param baseName string
param logAnalyticsWorkspaceResourceId string
param enablePolicyGuardrails bool
@description('Export the subscription activity log to the workspace (one landing zone per subscription does).')
param deployActivityLog bool = true
param allowedLocations string[]
param enableDefenderForCloud bool
param monthlyBudgetAmount int
param budgetStartDate string
param alertEmailAddresses string[]

@description('Action group the budget calls at budgetActionPercent of actual cost (the auto-shutdown trigger). Empty = none.')
param budgetActionGroupId string = ''
param budgetActionPercent int = 100

// Built-in policy definitions.
resource allowedLocationsDefinition 'Microsoft.Authorization/policyDefinitions@2023-04-01' existing = {
  scope: tenant()
  name: 'e56962a6-4747-49cd-b67b-bf8b01975c4c'
}

resource allowedRgLocationsDefinition 'Microsoft.Authorization/policyDefinitions@2023-04-01' existing = {
  scope: tenant()
  name: 'e765b5de-1225-4ba3-bd56-1ac6695af988'
}

resource inheritRgTagDefinition 'Microsoft.Authorization/policyDefinitions@2023-04-01' existing = {
  scope: tenant()
  name: 'ea3f2387-9b95-492a-a190-fcdc54f7b070'
}

var tagContributorRoleId = '4a9ae827-6dc8-4573-8ac7-8239d42aa03f'
var assignmentMetadata = {
  assignedBy: 'AVD landing zone (Bicep)'
  source: 'https://github.com/avd-ops/avd-landing-zone'
}
var governedTags = [
  'environment'
  'workload'
]

// ---------- Azure Policy ----------
resource allowedLocationsAssignment 'Microsoft.Authorization/policyAssignments@2024-04-01' = if (enablePolicyGuardrails) {
  name: 'avdlz-allowed-locations'
  properties: {
    displayName: 'AVD LZ: allowed locations for resources'
    description: 'Denies resources outside the regions approved for this AVD landing zone.'
    metadata: assignmentMetadata
    policyDefinitionId: allowedLocationsDefinition.id
    parameters: {
      listOfAllowedLocations: { value: allowedLocations }
    }
  }
}

resource allowedRgLocationsAssignment 'Microsoft.Authorization/policyAssignments@2024-04-01' = if (enablePolicyGuardrails) {
  name: 'avdlz-allowed-rg-locations'
  properties: {
    displayName: 'AVD LZ: allowed locations for resource groups'
    description: 'Denies resource groups outside the regions approved for this AVD landing zone.'
    metadata: assignmentMetadata
    policyDefinitionId: allowedRgLocationsDefinition.id
    parameters: {
      listOfAllowedLocations: { value: allowedLocations }
    }
  }
}

// Tags are inherited (Modify) rather than required (Deny): a Deny on untagged
// resource groups also blocks the ones Azure creates itself, e.g. NetworkWatcherRG.
// Modify-effect policies need an identity with rights to write tags.
resource inheritTagAssignments 'Microsoft.Authorization/policyAssignments@2024-04-01' = [
  for tag in governedTags: if (enablePolicyGuardrails) {
    name: 'avdlz-inherit-rg-tag-${tag}'
    location: location
    identity: {
      type: 'SystemAssigned'
    }
    properties: {
      displayName: 'AVD LZ: inherit tag "${tag}" from resource group'
      description: 'Copies the "${tag}" tag from the resource group to resources that lack it, for cost and ownership reporting.'
      metadata: assignmentMetadata
      policyDefinitionId: inheritRgTagDefinition.id
      parameters: {
        tagName: { value: tag }
      }
    }
  }
]

resource inheritTagRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for (tag, i) in governedTags: if (enablePolicyGuardrails) {
    name: guid(subscription().id, 'avdlz-inherit-rg-tag', tag)
    properties: {
      principalId: inheritTagAssignments[i]!.identity.principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', tagContributorRoleId)
    }
  }
]

// ---------- Defender for Cloud ----------
// Pricings are updated one at a time; parallel PUTs on the same subscription conflict.
resource defenderServers 'Microsoft.Security/pricings@2024-01-01' = if (enableDefenderForCloud) {
  name: 'VirtualMachines'
  properties: {
    pricingTier: 'Standard'
    subPlan: 'P2'
  }
}

resource defenderStorage 'Microsoft.Security/pricings@2024-01-01' = if (enableDefenderForCloud) {
  name: 'StorageAccounts'
  properties: {
    pricingTier: 'Standard'
    subPlan: 'DefenderForStorageV2'
  }
  dependsOn: [
    defenderServers
  ]
}

resource defenderKeyVault 'Microsoft.Security/pricings@2024-01-01' = if (enableDefenderForCloud) {
  name: 'KeyVaults'
  properties: {
    pricingTier: 'Standard'
    subPlan: 'PerKeyVault'
  }
  dependsOn: [
    defenderStorage
  ]
}

// ---------- Budget ----------
var deployBudget = monthlyBudgetAmount > 0 && !empty(budgetStartDate) && !empty(alertEmailAddresses)

resource budget 'Microsoft.Consumption/budgets@2023-11-01' = if (deployBudget) {
  name: 'budget-${baseName}'
  properties: {
    category: 'Cost'
    amount: monthlyBudgetAmount
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: budgetStartDate
    }
    notifications: union({
      actual80: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 80
        thresholdType: 'Actual'
        contactEmails: alertEmailAddresses
      }
      forecast100: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 100
        thresholdType: 'Forecasted'
        contactEmails: alertEmailAddresses
      }
    }, empty(budgetActionGroupId) ? {} : {
      // Auto shutdown (decision 0011): at this share of actual cost the action group starts the runbook.
      autoShutdown: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: budgetActionPercent
        thresholdType: 'Actual'
        contactEmails: alertEmailAddresses
        contactGroups: [
          budgetActionGroupId
        ]
      }
    })
  }
}

// ---------- Activity log -> Log Analytics ----------
resource activityLog 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (deployActivityLog) {
  name: 'avdlz-activity-log'
  properties: {
    workspaceId: logAnalyticsWorkspaceResourceId
    logs: [
      for category in [
        'Administrative'
        'Security'
        'ServiceHealth'
        'Alert'
        'Recommendation'
        'Policy'
        'Autoscale'
        'ResourceHealth'
      ]: {
        category: category
        enabled: true
      }
    ]
  }
}
