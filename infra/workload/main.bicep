targetScope = 'resourceGroup'

metadata description = 'Hotel-booking workload — test environment. Lands the .NET 10 API + React SPA on Azure Container Apps inside the existing spoke, with Azure SQL (Entra-only, passwordless), Key Vault, ACR, Log Analytics, and Application Insights. Implements the distributed Private DNS pattern.'

// -----------------------------------------------------------------------------
// Parameters
// -----------------------------------------------------------------------------

@description('Azure region. Defaults to swedencentral (matches the hub).')
param location string = resourceGroup().location

@description('Workload short name used in CAF names.')
@maxLength(10)
param workloadName string = 'hotel'

@description('Environment token used in CAF names.')
@allowed([
  'test'
  'prod'
])
param environmentName string = 'test'

@description('Region short code embedded in CAF names. Sweden Central = swc.')
param regionShortCode string = 'swc'

@description('Suffix used for resources that need global uniqueness (ACR, SQL server, KV). Derived from the resource group ID by default.')
param uniqueSuffix string = take(uniqueString(resourceGroup().id), 6)

@description('Spoke VNet name. The workload lands inside this VNet.')
param spokeVnetName string = 'vnet-${workloadName}-${environmentName}'

@description('Container Apps subnet name inside the spoke VNet (delegated to Microsoft.App/environments).')
param containerAppsSubnetName string = 'snet-aca-${workloadName}-${environmentName}'

@description('Private-endpoint subnet name inside the spoke VNet.')
param privateEndpointSubnetName string = 'snet-pe-${workloadName}-${environmentName}'

@description('ACR SKU. Standard supports MI pull and is the workshop default.')
@allowed([
  'Basic'
  'Standard'
  'Premium'
])
param acrSku string = 'Standard'

@description('Azure SQL database SKU. Serverless General Purpose by default so test idles to near-zero compute.')
param sqlDatabaseSku object = {
  name: 'GP_S_Gen5_1'
  tier: 'GeneralPurpose'
  family: 'Gen5'
  capacity: 1
}

@description('Auto-pause delay for the serverless SQL database, in minutes. -1 disables auto-pause.')
param sqlAutoPauseDelayMinutes int = 60

@description('Minimum vCore capacity for the serverless SQL database.')
param sqlMinCapacity string = '0.5'

@description('Maximum size of the SQL database, in bytes. 32 GiB by default.')
param sqlMaxSizeBytes int = 34359738368

@description('Log Analytics retention in days.')
@minValue(30)
@maxValue(730)
param logAnalyticsRetentionDays int = 30

@description('Placeholder container image used on first deployment before real images are pushed. MCR-hosted Hello World style image so the app can stand up.')
param placeholderContainerImage string = 'mcr.microsoft.com/k8se/quickstart:latest'

@description('Image reference (registry/repo:tag) for the API container app. Defaults to the placeholder; the deploy script reads the live image and passes it through so re-deploying an existing environment does not revert revisions to the placeholder.')
param apiContainerImage string = placeholderContainerImage

@description('Image reference (registry/repo:tag) for the web container app. Defaults to the placeholder; the deploy script reads the live image and passes it through so re-deploying an existing environment does not revert revisions to the placeholder.')
param webContainerImage string = placeholderContainerImage

@description('Minimum replicas for the API container app. Set to 0 in cost-optimised environments to allow scale-to-zero; set to 3 (or more) in zone-redundant environments to keep one replica in each availability zone at all times.')
@minValue(0)
param apiMinReplicas int = 0

@description('Maximum replicas for the API container app.')
@minValue(1)
param apiMaxReplicas int = 3

@description('Minimum replicas for the web container app. Same semantics as apiMinReplicas.')
@minValue(0)
param webMinReplicas int = 0

@description('Maximum replicas for the web container app.')
@minValue(1)
param webMaxReplicas int = 3

@description('Whether the Container Apps environment is zone-redundant. Set at creation and CANNOT be changed afterwards — existing environments keep whatever value they were created with, regardless of this parameter.')
param containerAppsEnvZoneRedundant bool = false

@description('Whether the SQL database is zone-redundant. Requires a region with three availability zones and a compatible SKU (GP_S, GP, BC).')
param sqlDatabaseZoneRedundant bool = false

@description('Common tags applied to every resource.')
param tags object = {
  workload: workloadName
  environment: environmentName
  managedBy: 'bicep'
}

// -----------------------------------------------------------------------------
// Naming (CAF)
// -----------------------------------------------------------------------------

var namePrefix = '${workloadName}-${environmentName}'
var nameSuffix = '-${regionShortCode}'

var runtimeIdentityName = 'id-${namePrefix}-rt'
var cicdIdentityName = 'id-${namePrefix}-cicd'
var logAnalyticsName = 'log-${namePrefix}${nameSuffix}'
var appInsightsName = 'appi-${namePrefix}${nameSuffix}'
var keyVaultName = 'kv-${namePrefix}-${uniqueSuffix}'
var containerRegistryName = toLower('cr${workloadName}${environmentName}${uniqueSuffix}')
var sqlServerName = 'sql-${namePrefix}-${uniqueSuffix}'
var sqlDatabaseName = 'sqldb-${namePrefix}'
var containerAppsEnvName = 'cae-${namePrefix}${nameSuffix}'
var apiContainerAppName = 'ca-${workloadName}api-${environmentName}${nameSuffix}-001'
var webContainerAppName = 'ca-${workloadName}web-${environmentName}${nameSuffix}-001'
var sqlPrivateEndpointName = 'pep-sql-${namePrefix}'
var keyVaultPrivateEndpointName = 'pep-kv-${namePrefix}'

// SQL Entra admin login name (display only — actual identity is the runtime UAMI's principal ID).
var sqlEntraAdminLogin = runtimeIdentityName

// -----------------------------------------------------------------------------
// Existing references
// -----------------------------------------------------------------------------

resource spokeVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: spokeVnetName
}

resource containerAppsSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: spokeVnet
  name: containerAppsSubnetName
}

resource privateEndpointSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: spokeVnet
  name: privateEndpointSubnetName
}

// -----------------------------------------------------------------------------
// Identities
// -----------------------------------------------------------------------------

module runtimeIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.5.1' = {
  name: 'mi-runtime'
  params: {
    name: runtimeIdentityName
    location: location
    tags: tags
  }
}

module cicdIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.5.1' = {
  name: 'mi-cicd'
  params: {
    name: cicdIdentityName
    location: location
    tags: tags
  }
}

// -----------------------------------------------------------------------------
// Observability (public ingestion — workshop rule)
// -----------------------------------------------------------------------------

module logAnalytics 'br/public:avm/res/operational-insights/workspace:0.15.1' = {
  name: 'log-analytics'
  params: {
    name: logAnalyticsName
    location: location
    tags: tags
    skuName: 'PerGB2018'
    dataRetention: logAnalyticsRetentionDays
  }
}

module appInsights 'br/public:avm/res/insights/component:0.7.2' = {
  name: 'app-insights'
  params: {
    name: appInsightsName
    location: location
    tags: tags
    workspaceResourceId: logAnalytics.outputs.resourceId
    applicationType: 'web'
    kind: 'web'
  }
}

// -----------------------------------------------------------------------------
// Container Registry (public — workshop rule)
// -----------------------------------------------------------------------------

module containerRegistry 'br/public:avm/res/container-registry/registry:0.12.1' = {
  name: 'acr'
  params: {
    name: containerRegistryName
    location: location
    tags: tags
    acrSku: acrSku
    acrAdminUserEnabled: false
    publicNetworkAccess: 'Enabled'
    networkRuleSetDefaultAction: 'Allow'
    roleAssignments: [
      {
        principalId: runtimeIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'AcrPull'
      }
      {
        principalId: cicdIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'AcrPull'
      }
      {
        principalId: cicdIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'AcrPush'
      }
    ]
  }
}

// -----------------------------------------------------------------------------
// Private DNS zones — distributed model (live in the workload RG, linked to spoke only).
// The hub vnet is intentionally NOT linked: a single vnet cannot be linked to two
// zones with the same name, so a shared hub forbids per-env hub linkage when
// multiple workload envs exist. The hub also hosts no client that needs to
// resolve workload-private endpoints.
// -----------------------------------------------------------------------------

module sqlPrivateDnsZone 'br/public:avm/res/network/private-dns-zone:0.8.1' = {
  name: 'pdz-sql'
  params: {
    name: 'privatelink${environment().suffixes.sqlServerHostname}'
    tags: tags
    virtualNetworkLinks: [
      {
        name: 'link-spoke'
        virtualNetworkResourceId: spokeVnet.id
        registrationEnabled: false
      }
    ]
  }
}

module keyVaultPrivateDnsZone 'br/public:avm/res/network/private-dns-zone:0.8.1' = {
  name: 'pdz-kv'
  params: {
    name: 'privatelink.vaultcore.azure.net'
    tags: tags
    virtualNetworkLinks: [
      {
        name: 'link-spoke'
        virtualNetworkResourceId: spokeVnet.id
        registrationEnabled: false
      }
    ]
  }
}

// -----------------------------------------------------------------------------
// Key Vault (private)
// -----------------------------------------------------------------------------

module keyVault 'br/public:avm/res/key-vault/vault:0.13.3' = {
  name: 'kv'
  params: {
    name: keyVaultName
    location: location
    tags: tags
    sku: 'standard'
    enableRbacAuthorization: true
    enableSoftDelete: true
    enablePurgeProtection: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
    privateEndpoints: [
      {
        name: keyVaultPrivateEndpointName
        subnetResourceId: privateEndpointSubnet.id
        service: 'vault'
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: keyVaultPrivateDnsZone.outputs.resourceId
            }
          ]
        }
      }
    ]
    roleAssignments: [
      {
        principalId: runtimeIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'Key Vault Secrets User'
      }
    ]
  }
}

// -----------------------------------------------------------------------------
// Azure SQL (private, Entra-only, runtime UAMI is the Entra admin)
// -----------------------------------------------------------------------------

module sqlServer 'br/public:avm/res/sql/server:0.21.2' = {
  name: 'sql'
  params: {
    name: sqlServerName
    location: location
    tags: tags
    publicNetworkAccess: 'Disabled'
    administrators: {
      azureADOnlyAuthentication: true
      login: sqlEntraAdminLogin
      principalType: 'Application'
      sid: runtimeIdentity.outputs.principalId
      tenantId: subscription().tenantId
    }
    databases: [
      {
        name: sqlDatabaseName
        sku: sqlDatabaseSku
        autoPauseDelay: sqlAutoPauseDelayMinutes
        minCapacity: sqlMinCapacity
        maxSizeBytes: sqlMaxSizeBytes
        zoneRedundant: sqlDatabaseZoneRedundant
        availabilityZone: -1
      }
    ]
    privateEndpoints: [
      {
        name: sqlPrivateEndpointName
        subnetResourceId: privateEndpointSubnet.id
        service: 'sqlServer'
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: sqlPrivateDnsZone.outputs.resourceId
            }
          ]
        }
      }
    ]
  }
}

// -----------------------------------------------------------------------------
// Container Apps environment (VNet-integrated, external load balancer)
// External so the frontend container app (ingressExternal: true) gets a public
// FQDN. The backend container app keeps ingressExternal: false and is reachable
// only via *.internal.<defaultDomain> from inside the env / spoke.
// -----------------------------------------------------------------------------

module containerAppsEnv 'br/public:avm/res/app/managed-environment:0.13.3' = {
  name: 'cae'
  params: {
    name: containerAppsEnvName
    location: location
    tags: tags
    infrastructureSubnetResourceId: containerAppsSubnet.id
    internal: false
    zoneRedundant: containerAppsEnvZoneRedundant
    publicNetworkAccess: 'Enabled'
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsWorkspaceResourceId: logAnalytics.outputs.resourceId
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

// -----------------------------------------------------------------------------
// Container apps
// -----------------------------------------------------------------------------

// Backend connection string built from resource properties. No secret material.
// Authentication=Active Directory Default lets the runtime UAMI authenticate via the AZURE_CLIENT_ID env var.
var sqlConnectionString = 'Server=tcp:${sqlServer.outputs.fullyQualifiedDomainName},1433;Database=${sqlDatabaseName};Authentication=Active Directory Default;Encrypt=True;'

module apiContainerApp 'br/public:avm/res/app/container-app:0.22.1' = {
  name: 'ca-api'
  params: {
    name: apiContainerAppName
    location: location
    tags: tags
    environmentResourceId: containerAppsEnv.outputs.resourceId
    managedIdentities: {
      userAssignedResourceIds: [
        runtimeIdentity.outputs.resourceId
      ]
    }
    workloadProfileName: 'Consumption'
    ingressExternal: false
    // Backend (.NET) listens on 8080 via ASPNETCORE_URLS env var below.
    ingressTargetPort: 8080
    ingressTransport: 'auto'
    // Internal-only ingress: east-west traffic from the web container app
    // stays on the Microsoft backbone inside the env, so HTTP is acceptable
    // and avoids forcing the nginx reverse proxy to terminate TLS twice.
    ingressAllowInsecure: true
    scaleSettings: {
      minReplicas: apiMinReplicas
      maxReplicas: apiMaxReplicas
    }
    registries: [
      {
        server: containerRegistry.outputs.loginServer
        identity: runtimeIdentity.outputs.resourceId
      }
    ]
    containers: [
      {
        name: 'api'
        image: apiContainerImage
        resources: {
          cpu: json('0.5')
          memory: '1Gi'
        }
        env: [
          {
            name: 'ConnectionStrings__HotelDb'
            value: sqlConnectionString
          }
          {
            name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
            value: appInsights.outputs.connectionString
          }
          {
            name: 'AZURE_CLIENT_ID'
            value: runtimeIdentity.outputs.clientId
          }
          {
            name: 'ASPNETCORE_URLS'
            value: 'http://+:8080'
          }
        ]
      }
    ]
  }
}

module webContainerApp 'br/public:avm/res/app/container-app:0.22.1' = {
  name: 'ca-web'
  params: {
    name: webContainerAppName
    location: location
    tags: tags
    environmentResourceId: containerAppsEnv.outputs.resourceId
    managedIdentities: {
      userAssignedResourceIds: [
        runtimeIdentity.outputs.resourceId
      ]
    }
    workloadProfileName: 'Consumption'
    ingressExternal: true
    // Frontend nginx listens on 80.
    ingressTargetPort: 80
    ingressTransport: 'auto'
    ingressAllowInsecure: false
    scaleSettings: {
      minReplicas: webMinReplicas
      maxReplicas: webMaxReplicas
    }
    registries: [
      {
        server: containerRegistry.outputs.loginServer
        identity: runtimeIdentity.outputs.resourceId
      }
    ]
    containers: [
      {
        name: 'web'
        image: webContainerImage
        resources: {
          cpu: json('0.25')
          memory: '0.5Gi'
        }
        env: [
          {
            name: 'API_INTERNAL_FQDN'
            // nginx reverse-proxy target inside the env (internal ingress).
            value: '${apiContainerAppName}.internal.${containerAppsEnv.outputs.defaultDomain}'
          }
          {
            name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
            value: appInsights.outputs.connectionString
          }
        ]
      }
    ]
  }
}

// -----------------------------------------------------------------------------
// Outputs (no secrets)
// -----------------------------------------------------------------------------

output runtimeIdentityClientId string = runtimeIdentity.outputs.clientId
output runtimeIdentityPrincipalId string = runtimeIdentity.outputs.principalId
output runtimeIdentityResourceId string = runtimeIdentity.outputs.resourceId

output cicdIdentityClientId string = cicdIdentity.outputs.clientId
output cicdIdentityPrincipalId string = cicdIdentity.outputs.principalId
output cicdIdentityResourceId string = cicdIdentity.outputs.resourceId

output containerRegistryLoginServer string = containerRegistry.outputs.loginServer
output containerRegistryName string = containerRegistry.outputs.name

output logAnalyticsWorkspaceResourceId string = logAnalytics.outputs.resourceId
output appInsightsResourceId string = appInsights.outputs.resourceId

output keyVaultUri string = keyVault.outputs.uri
output keyVaultName string = keyVault.outputs.name

output sqlServerFqdn string = sqlServer.outputs.fullyQualifiedDomainName
output sqlDatabaseName string = sqlDatabaseName

output containerAppsEnvName string = containerAppsEnv.outputs.name
output containerAppsEnvDefaultDomain string = containerAppsEnv.outputs.defaultDomain

output apiContainerAppName string = apiContainerApp.outputs.name
output apiContainerAppInternalFqdn string = '${apiContainerAppName}.internal.${containerAppsEnv.outputs.defaultDomain}'
output webContainerAppName string = webContainerApp.outputs.name
output webContainerAppFqdn string = webContainerApp.outputs.fqdn
