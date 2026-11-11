@description('Deployment region.')
param location string = resourceGroup().location

@description('Globally unique namespace name.')
param namespaceName string

@description('Queue that receives the outbox deliveries.')
param queueName string = 'order-events'

@description('Topic used by the fan-out samples.')
param topicName string = 'order-events-topic'

@description('Entra object ids granted send and receive on the data plane.')
param dataPlanePrincipalIds array = []

// Standard, not Basic: Basic has neither topics nor duplicate detection, and duplicate detection
// is the entire point of sample 09. Premium costs many times more and buys nothing here.
resource namespace 'Microsoft.ServiceBus/namespaces@2024-01-01' = {
  name: namespaceName
  location: location
  sku: {
    name: 'Standard'
    tier: 'Standard'
  }
  properties: {
    // The samples authenticate with Entra. Leaving SAS enabled would let a reader paste a
    // connection string into configuration and never notice they had stopped using identity.
    disableLocalAuth: true
    minimumTlsVersion: '1.2'
  }
}

resource queue 'Microsoft.ServiceBus/namespaces/queues@2024-01-01' = {
  parent: namespace
  name: queueName
  properties: {
    // The outbox guarantees at-least-once, so the broker will sometimes see the same MessageId
    // twice. With this on, and MessageIdSource = OutboxId, the broker collapses the retry into
    // one message and the consumer sees exactly one delivery.
    requiresDuplicateDetection: true
    duplicateDetectionHistoryTimeWindow: 'PT10M'

    maxDeliveryCount: 10
    lockDuration: 'PT1M'
    defaultMessageTimeToLive: 'P1D'
    deadLetteringOnMessageExpiration: true
  }
}

resource topic 'Microsoft.ServiceBus/namespaces/topics@2024-01-01' = {
  parent: namespace
  name: topicName
  properties: {
    requiresDuplicateDetection: true
    duplicateDetectionHistoryTimeWindow: 'PT10M'
    defaultMessageTimeToLive: 'P1D'
  }
}

// Built-in role definition ids, hard-coded because they are identical in every subscription.
var dataSenderRoleId = '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39'
var dataReceiverRoleId = '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0'

resource senderAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in dataPlanePrincipalIds: {
    name: guid(namespace.id, principalId, dataSenderRoleId)
    scope: namespace
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', dataSenderRoleId)
      principalId: principalId
    }
  }
]

resource receiverAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in dataPlanePrincipalIds: {
    name: guid(namespace.id, principalId, dataReceiverRoleId)
    scope: namespace
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', dataReceiverRoleId)
      principalId: principalId
    }
  }
]

@description('Fully qualified namespace, which is what ServiceBusClient takes when using Entra.')
output fullyQualifiedNamespace string = '${namespace.name}.servicebus.windows.net'

output namespaceName string = namespace.name
output queueName string = queue.name
output topicName string = topic.name
