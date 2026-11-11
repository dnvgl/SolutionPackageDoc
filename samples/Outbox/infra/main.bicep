targetScope = 'resourceGroup'

@description('Deployment region. Pricing in the sample READMEs was verified for southeastasia.')
param location string = resourceGroup().location

@description('Which samples to provision. Pass only what you need; everything costs money.')
param samples array = []

@description('Entra object ids that run the samples locally and need data-plane access.')
param developerObjectIds array = []

@description('Email addresses notified by the budget alert.')
param budgetContactEmails array

@description('First day of the budget period, as yyyy-MM-01.')
param budgetStartDate string = '${substring(utcNow('yyyy-MM-dd'), 0, 7)}-01'

@description('Monthly budget in USD for this resource group.')
param budgetAmount int = 50

// Sample 10 publishes through Dapr, which is backed by this same namespace - so asking for 10
// implies asking for Service Bus. main.bicep resolves that rather than expecting the reader to
// know it.
var needsServiceBus = !empty(intersection(samples, ['09', '10']))

// Namespace names are globally unique and must survive a redeploy unchanged, so derive one from
// the resource group id rather than from anything the caller types.
var namespaceName = 'sb-outbox-${uniqueString(resourceGroup().id)}'

module serviceBus 'modules/servicebus.bicep' = if (needsServiceBus) {
  name: 'servicebus'
  params: {
    location: location
    namespaceName: namespaceName
    dataPlanePrincipalIds: developerObjectIds
  }
}

// Always deployed, whatever is in `samples`. It is the safety net behind every other cost
// decision, and it is free.
module budget 'modules/budget.bicep' = {
  name: 'budget'
  params: {
    amount: budgetAmount
    contactEmails: budgetContactEmails
    startDate: budgetStartDate
  }
}

output serviceBusNamespace string = needsServiceBus ? serviceBus!.outputs.fullyQualifiedNamespace : ''
output serviceBusQueue string = needsServiceBus ? serviceBus!.outputs.queueName : ''
output serviceBusTopic string = needsServiceBus ? serviceBus!.outputs.topicName : ''
