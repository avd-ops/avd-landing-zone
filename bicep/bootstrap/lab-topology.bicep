// =====================================================================
// Lab topology — 4-to-5-subscription ALZ Management Groups, MCA vending, and budgets
// Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
//
// Deployed at TENANT scope (requires temporary Tenant Root Group elevation).
// Implements avd-ops ADR 0019 for Bicep-only shops.
// =====================================================================

targetScope = 'tenant'

@description('Short lowercase prefix for Management Group IDs and vended subscription aliases (2-16 chars).')
@minLength(2)
@maxLength(16)
param prefix string = 'avdlz'

@description('When true, vend subscriptions not already present in existingSubscriptionIds using billingScopeId (MCA only).')
param vendSubscriptions bool = false

@description('Include a second AVD workload spoke subscription (lz-avd-workload-2) under landing-zones.')
param enableSecondWorkloadSpoke bool = false

@description('MCA billing scope ID (/providers/Microsoft.Billing/billingAccounts/.../invoiceSections/...) required when vendSubscriptions is true.')
param billingScopeId string = ''

@description('Map of role key (platform-connectivity, platform-management, lz-avd-workload, lz-avd-workload-2, sandbox-ci) to existing subscription GUID.')
param existingSubscriptionIds object = {}

@description('Monthly Azure Consumption Budget amount (USD) applied to each existing subscription.')
@minValue(1)
param monthlyBudgetAmount int = 50

@description('First-of-month start date in YYYY-MM-01T00:00:00Z format.')
param budgetStartDate string

@description('Email addresses notified when subscription spend crosses 50%, 80%, or 100%.')
@minLength(1)
param budgetAlertEmails array

var baseRoles = [
  {
    key: 'platform-connectivity'
    mgSuffix: 'platform-connectivity'
    workload: 'Production'
  }
  {
    key: 'platform-management'
    mgSuffix: 'platform-management'
    workload: 'Production'
  }
  {
    key: 'lz-avd-workload'
    mgSuffix: 'landing-zones'
    workload: 'DevTest'
  }
  {
    key: 'sandbox-ci'
    mgSuffix: 'sandbox'
    workload: 'DevTest'
  }
]

var allRoles = enableSecondWorkloadSpoke || contains(existingSubscriptionIds, 'lz-avd-workload-2')
  ? concat(baseRoles, [
      {
        key: 'lz-avd-workload-2'
        mgSuffix: 'landing-zones'
        workload: 'DevTest'
      }
    ])
  : baseRoles

var rolesToVend = [for r in allRoles: if (vendSubscriptions && !contains(existingSubscriptionIds, r.key)) r]
var existingRoles = [for r in allRoles: if (contains(existingSubscriptionIds, r.key)) r]

resource mgPlatform 'Microsoft.Management/managementGroups@2023-04-01' = {
  name: '${prefix}-platform'
  properties: {
    displayName: 'platform'
  }
}

resource mgPlatformConnectivity 'Microsoft.Management/managementGroups@2023-04-01' = {
  name: '${prefix}-platform-connectivity'
  properties: {
    displayName: 'connectivity'
    details: {
      parent: {
        id: mgPlatform.id
      }
    }
  }
}

resource mgPlatformManagement 'Microsoft.Management/managementGroups@2023-04-01' = {
  name: '${prefix}-platform-management'
  properties: {
    displayName: 'management'
    details: {
      parent: {
        id: mgPlatform.id
      }
    }
  }
}

resource mgLandingZones 'Microsoft.Management/managementGroups@2023-04-01' = {
  name: '${prefix}-landing-zones'
  properties: {
    displayName: 'landing-zones'
  }
}

resource mgSandbox 'Microsoft.Management/managementGroups@2023-04-01' = {
  name: '${prefix}-sandbox'
  properties: {
    displayName: 'sandbox'
  }
}

resource mgDecommissioned 'Microsoft.Management/managementGroups@2023-04-01' = {
  name: '${prefix}-decommissioned'
  properties: {
    displayName: 'decommissioned'
  }
}

resource vendedSubscriptions 'Microsoft.Subscription/aliases@2021-10-01' = [
  for r in rolesToVend: {
    name: '${prefix}-${r.key}'
    properties: {
      billingScope: billingScopeId
      displayName: '${prefix}-${r.key}'
      workload: r.workload
      additionalProperties: {
        managementGroupId: tenantResourceId('Microsoft.Management/managementGroups', '${prefix}-${r.mgSuffix}')
      }
    }
    dependsOn: [
      mgPlatformConnectivity
      mgPlatformManagement
      mgLandingZones
      mgSandbox
    ]
  }
]

resource existingAssociations 'Microsoft.Management/managementGroups/subscriptions@2023-04-01' = [
  for r in existingRoles: {
    name: '${prefix}-${r.mgSuffix}/${existingSubscriptionIds[r.key]}'
    dependsOn: [
      mgPlatformConnectivity
      mgPlatformManagement
      mgLandingZones
      mgSandbox
    ]
  }
]

module existingBudgets 'modules/subscriptionBudget.bicep' = [
  for r in existingRoles: {
    name: 'budget-${r.key}'
    scope: subscription(existingSubscriptionIds[r.key])
    params: {
      budgetName: '${prefix}-${r.key}-monthly'
      monthlyAmount: monthlyBudgetAmount
      startDate: budgetStartDate
      contactEmails: budgetAlertEmails
    }
  }
]

output managementGroupIds object = {
  platform: mgPlatform.id
  platformConnectivity: mgPlatformConnectivity.id
  platformManagement: mgPlatformManagement.id
  landingZones: mgLandingZones.id
  sandbox: mgSandbox.id
  decommissioned: mgDecommissioned.id
}

output vendedSubscriptionAliasIds array = [for (r, i) in rolesToVend: vendedSubscriptions[i].id]
