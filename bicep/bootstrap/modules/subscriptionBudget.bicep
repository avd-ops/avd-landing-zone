// =====================================================================
// Lab topology — per-subscription monthly Azure Consumption Budget
// Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
// =====================================================================

targetScope = 'subscription'

@description('Budget resource name.')
param budgetName string

@description('Monthly budget amount in USD.')
@minValue(1)
param monthlyAmount int = 50

@description('First-of-month start date in YYYY-MM-01T00:00:00Z format.')
param startDate string

@description('Email addresses notified at 50% actual, 80% actual, and 100% forecasted.')
@minLength(1)
param contactEmails array

resource monthlyBudget 'Microsoft.Consumption/budgets@2023-11-01' = {
  name: budgetName
  properties: {
    category: 'Cost'
    amount: monthlyAmount
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: startDate
    }
    notifications: {
      actual50: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 50
        thresholdType: 'Actual'
        contactEmails: contactEmails
      }
      actual80: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 80
        thresholdType: 'Actual'
        contactEmails: contactEmails
      }
      forecasted100: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 100
        thresholdType: 'Forecasted'
        contactEmails: contactEmails
      }
    }
  }
}

output budgetId string = monthlyBudget.id
