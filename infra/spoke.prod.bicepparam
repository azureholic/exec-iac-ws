using './spoke.bicep'

// Prod spoke. Address space 10.20.0.0/22 — non-overlapping with the test
// spoke (10.10.0.0/22) and the hub (192.168.100.0/24). Peers to the hub
// only; prod and test never peer to each other.

param location = 'swedencentral'
param workloadName = 'hotel'
param environmentName = 'prod'
param spokeVnetAddressPrefix = '10.20.0.0/22'
param privateEndpointSubnetPrefix = '10.20.0.0/26'
param containerAppsSubnetPrefix = '10.20.2.0/23'
param hubResourceGroupName = 'rg-platform'
param hubVnetName = 'vnet-hub'
