using './spoke.bicep'

// Test spoke. Address space 10.10.0.0/22 — matches the workshop's existing
// rg-hotel-test deployment, peered bi-directionally with vnet-hub.

param location = 'swedencentral'
param workloadName = 'hotel'
param environmentName = 'test'
param spokeVnetAddressPrefix = '10.10.0.0/22'
param privateEndpointSubnetPrefix = '10.10.0.0/26'
param containerAppsSubnetPrefix = '10.10.2.0/23'
param hubResourceGroupName = 'rg-platform'
param hubVnetName = 'vnet-hub'
