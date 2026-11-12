@description('Deployment region.')
param location string = resourceGroup().location

@description('Container Apps managed environment name.')
param environmentName string = 'cae-outbox-samples'

@description('Container app name.')
param appName string = 'ca-outbox-scaleout'

@description('User-assigned identity name. Used for the registry pull, Service Bus and Azure SQL.')
param identityName string = 'id-outbox-scaleout'

@description('Container image to run, including registry and tag.')
param containerImage string

@description('Registry the image is pulled from.')
param registryName string

@description('Service Bus namespace backing the Dapr pub/sub component.')
param serviceBusNamespaceName string

@description('Topic the dispatcher publishes to. Must NOT have duplicate detection - see the README.')
param topicName string

@description('Dapr component name. Must match sample 07 so the application code is identical.')
param daprComponentName string = 'order-pubsub'

@description('Port the application listens on. Must equal ASPNETCORE_URLS below.')
param targetPort int = 8080

@description('Replicas kept running at all times. Two is the minimum that proves anything.')
param minReplicas int = 2

@description('Upper bound on replicas.')
param maxReplicas int = 4

@description('Azure SQL connection string. Entra auth, so it carries no secret.')
param sqlConnectionString string

@description('Log Analytics workspace name backing the environment.')
param workspaceName string = 'log-outbox-samples'

// ---------------------------------------------------------------------------------------------
// A user-assigned identity, not a system-assigned one.
//
// A system-assigned identity does not exist until the container app has been created, so its
// AcrPull role assignment cannot be made before the app's first image pull. The first revision
// then fails to pull and the deployment is dead on arrival. A user-assigned identity exists
// first, can be granted everything up front, and - unlike a system-assigned identity - exposes a
// client id that the Dapr component can be pointed at explicitly.
// ---------------------------------------------------------------------------------------------
resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
}

resource registry 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' existing = {
  name: registryName
}

resource serviceBusNamespace 'Microsoft.ServiceBus/namespaces@2024-01-01' existing = {
  name: serviceBusNamespaceName
}

var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
var dataSenderRoleId = '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39'

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, identity.id, acrPullRoleId)
  scope: registry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource serviceBusSender 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(serviceBusNamespace.id, identity.id, dataSenderRoleId)
  scope: serviceBusNamespace
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', dataSenderRoleId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource environment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: environmentName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: workspace.properties.customerId
        sharedKey: workspace.listKeys().primarySharedKey
      }
    }
  }
}

// The Dapr component is a child of the ENVIRONMENT, not of the app. Declaring it on the app is a
// common mistake and silently produces no component at all.
resource pubsub 'Microsoft.App/managedEnvironments/daprComponents@2024-03-01' = {
  parent: environment
  name: daprComponentName
  properties: {
    componentType: 'pubsub.azure.servicebus.topics'
    version: 'v1'
    metadata: [
      {
        name: 'namespaceName'
        value: '${serviceBusNamespaceName}.servicebus.windows.net'
      }
      {
        // The identity Dapr authenticates with. A system-assigned identity would be picked up
        // implicitly; a user-assigned one has to be named, and Dapr wants the CLIENT id - not
        // the principal id, which is the easy mistake and fails with an opaque auth error.
        name: 'azureClientId'
        value: identity.properties.clientId
      }
      {
        // Dapr creates topics and subscriptions on demand by default, which needs the Service Bus
        // *Manage* right. This identity deliberately only has Data Sender, so entity management
        // is turned off and the topic is created by servicebus.bicep instead. Leave this on and
        // the component fails to initialize with a permissions error that looks like a role
        // assignment problem.
        name: 'disableEntityManagement'
        value: 'true'
      }
    ]
    scopes: [
      appName
    ]
  }
}

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: appName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  dependsOn: [
    acrPull
    serviceBusSender
  ]
  properties: {
    managedEnvironmentId: environment.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        // Must equal the port the application actually listens on, which is pinned by
        // ASPNETCORE_URLS below. A mismatch here surfaces as an ingress 404 with a perfectly
        // healthy container.
        targetPort: targetPort
        transport: 'auto'
        allowInsecure: false
      }
      registries: [
        {
          server: registry.properties.loginServer
          identity: identity.id
        }
      ]
      dapr: {
        enabled: true
        appId: appName
        appPort: targetPort
        appProtocol: 'http'
      }
    }
    template: {
      containers: [
        {
          name: 'app'
          image: containerImage
          resources: {
            // 0.25 vCPU / 0.5 GiB is the smallest Consumption allocation. Two always-on replicas
            // at this size is roughly 1.3M vCPU-seconds a month against a 180k free grant; one
            // step up to 0.5 vCPU doubles the bill for a sample that is idle most of the time.
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: [
            {
              name: 'ASPNETCORE_URLS'
              value: 'http://+:${targetPort}'
            }
            {
              name: 'ConnectionStrings__Sales'

              // 'Active Directory Default' resolves to DefaultAzureCredential, which inside a
              // container app looks for a SYSTEM-assigned identity and finds none. A
              // user-assigned identity has to be named, so the authentication method is swapped
              // for the explicit one and the client id goes in User Id. Without this the
              // connection fails with a managed identity error that mentions no identity at all.
              value: replace(
                sqlConnectionString,
                'Authentication=Active Directory Default',
                'Authentication=Active Directory Managed Identity;User Id=${identity.properties.clientId}'
              )
            }
            {
              name: 'Dapr__PubSubName'
              value: daprComponentName
            }
            {
              name: 'Dapr__TopicName'
              value: topicName
            }
          ]
          probes: [
            {
              type: 'Liveness'
              httpGet: {
                path: '/health'
                port: targetPort
              }
              initialDelaySeconds: 10
              periodSeconds: 30
            }
          ]
        }
      ]
      scale: {
        // Pinned, not autoscaled on load. The sample's claim is about what several dispatchers do
        // to one table, so the replica count has to be deterministic while the test runs.
        minReplicas: minReplicas
        maxReplicas: maxReplicas
      }
    }
  }
}

output appFqdn string = containerApp.properties.configuration.ingress.fqdn
output appName string = containerApp.name
output environmentName string = environment.name
output identityClientId string = identity.properties.clientId
output identityPrincipalId string = identity.properties.principalId
output identityName string = identity.name
