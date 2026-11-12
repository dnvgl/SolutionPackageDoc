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

@description('Entra object id of the Azure SQL administrator. Required when a sample needs SQL.')
param sqlAdminObjectId string = ''

@description('Entra login name (UPN) of the Azure SQL administrator.')
param sqlAdminLogin string = ''

@description('Developer public IP allowed through the SQL firewall.')
param developerIpAddress string = ''

@description('Set false when the subscription free Azure SQL database is already in use elsewhere.')
param useSqlFreeLimit bool = true

@description('''
Image for the sample 10 container app, including registry and tag.

Left empty on the first provisioning run: the registry has to exist before an image can be pushed
to it, and the container app cannot be created without an image. deploy.ps1 pushes the image and
then re-runs this template with the value filled in. Empty means "registry and database only, no
container app yet" rather than "deploy a placeholder", because a placeholder revision that fails
its health probe is indistinguishable from a broken deployment.
''')
param containerImage string = ''

// Sample 10 publishes through Dapr, which is backed by this same namespace - so asking for 10
// implies asking for Service Bus. main.bicep resolves that rather than expecting the reader to
// know it.
var needsServiceBus = !empty(intersection(samples, ['09', '10']))

var needsScaleOut = contains(samples, '10')
var needsSql = needsScaleOut
var needsAcr = needsScaleOut
var needsContainerApps = needsScaleOut && !empty(containerImage)

// Namespace names are globally unique and must survive a redeploy unchanged, so derive one from
// the resource group id rather than from anything the caller types.
var namespaceName = 'sb-outbox-${uniqueString(resourceGroup().id)}'
var sqlServerName = 'sql-outbox-${uniqueString(resourceGroup().id)}'
var registryName = 'acroutbox${uniqueString(resourceGroup().id)}'
var scaleOutTopicName = 'scaleout-events'

module serviceBus 'modules/servicebus.bicep' = if (needsServiceBus) {
  name: 'servicebus'
  params: {
    location: location
    namespaceName: namespaceName
    dataPlanePrincipalIds: developerObjectIds
    createScaleOutTopic: needsScaleOut
    scaleOutTopicName: scaleOutTopicName
  }
}

module sql 'modules/sql.bicep' = if (needsSql) {
  name: 'sql'
  params: {
    location: location
    serverName: sqlServerName
    administratorObjectId: sqlAdminObjectId
    administratorLogin: sqlAdminLogin
    developerIpAddress: developerIpAddress
    useFreeLimit: useSqlFreeLimit
  }
}

module acr 'modules/acr.bicep' = if (needsAcr) {
  name: 'acr'
  params: {
    location: location
    registryName: registryName
  }
}

module containerApps 'modules/containerapps.bicep' = if (needsContainerApps) {
  name: 'containerapps'
  params: {
    location: location
    containerImage: containerImage
    registryName: registryName
    serviceBusNamespaceName: namespaceName
    topicName: scaleOutTopicName
    sqlConnectionString: needsSql ? sql!.outputs.connectionString : ''
  }
  dependsOn: [
    serviceBus
    acr
  ]
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
output scaleOutTopic string = needsScaleOut ? serviceBus!.outputs.scaleOutTopicName : ''
output scaleOutSubscription string = needsScaleOut ? serviceBus!.outputs.scaleOutSubscriptionName : ''

output sqlServerFqdn string = needsSql ? sql!.outputs.fullyQualifiedDomainName : ''
output sqlDatabaseName string = needsSql ? sql!.outputs.databaseName : ''
output sqlConnectionString string = needsSql ? sql!.outputs.connectionString : ''

output registryLoginServer string = needsAcr ? acr!.outputs.loginServer : ''
output registryName string = needsAcr ? acr!.outputs.registryName : ''

output containerAppFqdn string = needsContainerApps ? containerApps!.outputs.appFqdn : ''
output containerAppName string = needsContainerApps ? containerApps!.outputs.appName : ''
output containerAppIdentityName string = needsContainerApps ? containerApps!.outputs.identityName : ''
output containerAppIdentityClientId string = needsContainerApps ? containerApps!.outputs.identityClientId : ''
