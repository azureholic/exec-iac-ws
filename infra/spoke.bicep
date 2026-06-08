targetScope = 'resourceGroup'

@description('Azure region for the spoke resources.')
param location string = resourceGroup().location

@description('Short workload name used in resource names.')
@minLength(2)
@maxLength(16)
param workloadName string = 'hotel'

@description('Environment discriminator (e.g. test, prod).')
@minLength(2)
@maxLength(8)
param environmentName string = 'test'

@description('Address space for the spoke VNet. Must not overlap the hub (192.168.100.0/24) or other spokes.')
param spokeVnetAddressPrefix string = '10.10.0.0/22'

@description('Address prefix for the private-endpoint subnet. Must sit inside spokeVnetAddressPrefix.')
param privateEndpointSubnetPrefix string = '10.10.0.0/26'

@description('Address prefix for the Container Apps environment subnet. /23 minimum for ACA workload-profile envs.')
param containerAppsSubnetPrefix string = '10.10.2.0/23'

@description('Resource group that holds the hub VNet.')
param hubResourceGroupName string = 'rg-platform'

@description('Name of the hub VNet to peer with.')
param hubVnetName string = 'vnet-hub'

@description('Tags applied to all resources.')
param tags object = {
  workload: workloadName
  environment: environmentName
  role: 'spoke'
}

var spokeVnetName = 'vnet-${workloadName}-${environmentName}'
var privateEndpointSubnetName = 'snet-pe-${workloadName}-${environmentName}'
var containerAppsSubnetName = 'snet-aca-${workloadName}-${environmentName}'

// Reference the existing hub VNet (deployed by mock-alz/) so we can read its resource ID
// for the bi-directional peering. The hub lives in a different resource group.
resource hubVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: hubVnetName
  scope: resourceGroup(hubResourceGroupName)
}

// Spoke VNet with one PE subnet and bi-directional peering to the hub.
// The AVM virtual-network module creates the reverse peering on the hub via a nested
// deployment scoped to the hub's resource group (requires write access on the hub RG).
module spokeVnet 'br/public:avm/res/network/virtual-network:0.9.0' = {
  name: 'spoke-vnet-${environmentName}'
  params: {
    name: spokeVnetName
    location: location
    addressPrefixes: [
      spokeVnetAddressPrefix
    ]
    tags: tags
    subnets: [
      {
        name: privateEndpointSubnetName
        addressPrefix: privateEndpointSubnetPrefix
        privateEndpointNetworkPolicies: 'Disabled'
      }
      {
        name: containerAppsSubnetName
        addressPrefix: containerAppsSubnetPrefix
        delegation: 'Microsoft.App/environments'
      }
    ]
    peerings: [
      {
        remoteVirtualNetworkResourceId: hubVnet.id
        name: 'peer-${spokeVnetName}-to-${hubVnetName}'
        allowVirtualNetworkAccess: true
        allowForwardedTraffic: true
        allowGatewayTransit: false
        useRemoteGateways: false
        remotePeeringEnabled: true
        remotePeeringName: 'peer-${hubVnetName}-to-${spokeVnetName}'
        remotePeeringAllowVirtualNetworkAccess: true
        remotePeeringAllowForwardedTraffic: true
        remotePeeringAllowGatewayTransit: false
        remotePeeringUseRemoteGateways: false
      }
    ]
  }
}

output spokeVnetResourceId string = spokeVnet.outputs.resourceId
output spokeVnetName string = spokeVnet.outputs.name
output spokeVnetAddressSpace string = spokeVnetAddressPrefix
output privateEndpointSubnetResourceId string = spokeVnet.outputs.subnetResourceIds[0]
output containerAppsSubnetResourceId string = spokeVnet.outputs.subnetResourceIds[1]
