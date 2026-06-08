using './main.bicep'

// Test environment — cost-optimised. Same template + AVM modules as prod;
// only these values differ. Keep in sync with the existing rg-hotel-test
// deployment so re-running Deploy-Workload.ps1 -Environment test produces
// a clean no-op what-if.

param location = 'swedencentral'
param workloadName = 'hotel'
param environmentName = 'test'
param regionShortCode = 'swc'
param spokeVnetName = 'vnet-hotel-test'
param containerAppsSubnetName = 'snet-aca-hotel-test'
param privateEndpointSubnetName = 'snet-pe-hotel-test'

param acrSku = 'Standard'

// Serverless SQL with auto-pause — idles the data tier when test is idle.
// SKU name uses the short form (no trailing _<capacity>) because the SQL API
// normalises the name that way; sending the long form would cause what-if to
// flag a sku.name diff on every deploy.
param sqlDatabaseSku = {
  name: 'GP_S_Gen5'
  tier: 'GeneralPurpose'
  family: 'Gen5'
  capacity: 1
}
param sqlAutoPauseDelayMinutes = 60
param sqlMinCapacity = '0.5'
param sqlMaxSizeBytes = 34359738368
param sqlDatabaseZoneRedundant = false

param logAnalyticsRetentionDays = 30

// Container Apps env was created non-zone-redundant; the property cannot
// be flipped on an existing env so this stays false for test.
param containerAppsEnvZoneRedundant = false

// API keeps a warm floor of 1 replica to avoid cold-start latency on the
// nginx reverse-proxy path. Web tier still scale-to-zero (the public ingress
// can absorb a cold start without breaking the SPA).
param apiMinReplicas = 1
param apiMaxReplicas = 3
param webMinReplicas = 0
param webMaxReplicas = 3

param tags = {
  workload: 'hotel'
  environment: 'test'
  managedBy: 'bicep'
}
