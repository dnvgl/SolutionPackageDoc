targetScope = 'resourceGroup'

@description('Monthly budget in USD for the resource group.')
param amount int = 50

@description('Email addresses notified when the thresholds are crossed.')
param contactEmails array

@description('First day of the budget period, as yyyy-MM-01.')
param startDate string

// A budget costs nothing and is the only thing that notices a resource left running by accident.
// Forecasted alerts matter more than actual ones: by the time actual spend hits 100 percent the
// money is already gone, whereas the forecast fires while there is still time to tear down.
resource budget 'Microsoft.Consumption/budgets@2023-11-01' = {
  name: 'budget-outbox-samples'
  properties: {
    category: 'Cost'
    amount: amount
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: startDate
    }
    notifications: {
      ActualEightyPercent: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 80
        contactEmails: contactEmails
        thresholdType: 'Actual'
      }
      ForecastedHundredPercent: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 100
        contactEmails: contactEmails
        thresholdType: 'Forecasted'
      }
    }
  }
}

output budgetName string = budget.name
