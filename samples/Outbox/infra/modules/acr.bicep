@description('Deployment region.')
param location string = resourceGroup().location

@description('Globally unique registry name. Alphanumeric only, 5-50 characters.')
param registryName string

resource registry 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: registryName
  location: location
  sku: {
    // Basic is 0.1666 USD/day. Standard and Premium buy throughput and geo-replication that a
    // sample pushing one image has no use for.
    name: 'Basic'
  }
  properties: {
    // Both off deliberately. The admin user is a username/password pair that would end up in a
    // script, and anonymous pull would make the AcrPull role assignment meaningless. The
    // container app pulls with its managed identity.
    adminUserEnabled: false
    anonymousPullEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

output loginServer string = registry.properties.loginServer
output registryName string = registry.name
output registryId string = registry.id
