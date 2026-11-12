@description('Deployment region.')
param location string = resourceGroup().location

@description('Globally unique logical server name.')
param serverName string

@description('Database shared by every Azure sample. The free offer is one database per subscription.')
param databaseName string = 'sqldb-outbox-samples'

@description('Entra object id of the server administrator.')
param administratorObjectId string

@description('Entra login name (UPN) of the server administrator.')
param administratorLogin string

@description('Set false to provision on paid compute when the subscription free database is already taken.')
param useFreeLimit bool = true

@description('Public IP allowed through the firewall so the samples can connect from a developer machine.')
param developerIpAddress string = ''

resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: serverName
  location: location
  properties: {
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'

    // Entra-only. There is no SQL login and no password anywhere in this plan, so there is
    // nothing to leak into a connection string or a committed appsettings.json.
    administrators: {
      administratorType: 'ActiveDirectory'
      azureADOnlyAuthentication: true
      principalType: 'User'
      sid: administratorObjectId
      login: administratorLogin
      tenantId: subscription().tenantId
    }
  }
}

// ---------------------------------------------------------------------------------------------
// The most expensive line in this repository if it is wrong.
//
// GP_S_Gen5 serverless is billed per vCore-second at 0.620892 USD/vCore-hour once the free grant
// is gone - roughly 450 USD/month for a database nobody is using. Three properties keep that from
// happening and all three are mandatory:
//
//   useFreeLimit                : true      bill against the free 100,000 vCore-second grant
//   freeLimitExhaustionBehavior : AutoPause STOP when the grant runs out. The alternative,
//                                           'BillOverUsage', is the 450 USD/month door.
//   autoPauseDelay              : 60        minimum allowed; pause after an hour idle
//
// Verify them on the deployed resource, not here - a template that says the right thing and a
// resource that does the right thing are different claims. provision.ps1 reads them back.
// ---------------------------------------------------------------------------------------------
resource database 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sqlServer
  name: databaseName
  location: location
  sku: {
    name: 'GP_S_Gen5'
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: 1
  }
  properties: {
    autoPauseDelay: 60
    minCapacity: json('0.5')
    maxSizeBytes: 34359738368
    useFreeLimit: useFreeLimit
    freeLimitExhaustionBehavior: useFreeLimit ? 'AutoPause' : null
    zoneRedundant: false
    requestedBackupStorageRedundancy: 'Local'
  }
}

// Container Apps egresses from shared Azure address space, so the usual 0.0.0.0 pseudo-rule is
// what lets the sample 10 replicas connect. It does not open the server to the public internet:
// authentication is still Entra-only.
resource allowAzureServices 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = {
  parent: sqlServer
  name: 'AllowAllWindowsAzureIps'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource allowDeveloper 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = if (!empty(developerIpAddress)) {
  parent: sqlServer
  name: 'AllowDeveloper'
  properties: {
    startIpAddress: developerIpAddress
    endIpAddress: developerIpAddress
  }
}

output serverName string = sqlServer.name
output fullyQualifiedDomainName string = sqlServer.properties.fullyQualifiedDomainName
output databaseName string = database.name

@description('Ready to paste into configuration. Entra auth, so it carries no secret.')
output connectionString string = 'Server=tcp:${sqlServer.properties.fullyQualifiedDomainName},1433;Initial Catalog=${database.name};Encrypt=True;TrustServerCertificate=False;Authentication=Active Directory Default;Connect Timeout=90'
