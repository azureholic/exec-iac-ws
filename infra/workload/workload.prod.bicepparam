using './main.bicep'

// Prod environment — zone-redundant data tier, no scale-to-zero, separate
// spoke with a non-overlapping address space. Same template + AVM modules
// as test; only these values differ.

param location = 'swedencentral'
param workloadName = 'hotel'
param environmentName = 'prod'
param regionShortCode = 'swc'
param spokeVnetName = 'vnet-hotel-prod'
param containerAppsSubnetName = 'snet-aca-hotel-prod'
param privateEndpointSubnetName = 'snet-pe-hotel-prod'

param acrSku = 'Standard'

// Serverless SQL, larger vCore floor, zone-redundant, no auto-pause.
// GP_S supports zoneRedundant in regions with three availability zones
// (swedencentral qualifies). Short-form SKU name (no trailing _<capacity>)
// matches the way the SQL API stores it.
param sqlDatabaseSku = {
  name: 'GP_S_Gen5'
  tier: 'GeneralPurpose'
  family: 'Gen5'
  capacity: 2
}
param sqlAutoPauseDelayMinutes = -1
param sqlMinCapacity = '1'
param sqlMaxSizeBytes = 34359738368
param sqlDatabaseZoneRedundant = true

param logAnalyticsRetentionDays = 90

// Zone-redundant Container Apps env (set at create time only).
param containerAppsEnvZoneRedundant = true

// At least three replicas, no scale-to-zero — gives one replica per AZ
// so a single-zone outage still leaves the workload serving.
param apiMinReplicas = 3
param apiMaxReplicas = 10
param webMinReplicas = 3
param webMaxReplicas = 10

param tags = {
  workload: 'hotel'
  environment: 'prod'
  managedBy: 'bicep'
}
