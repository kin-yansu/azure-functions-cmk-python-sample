targetScope = 'resourceGroup'

param location string = resourceGroup().location
param hsmAdminObjectId string

var suffix = uniqueString(resourceGroup().id)
var privateDnsNames = [
  'privatelink.azurewebsites.net'
  'privatelink.blob.${environment().suffixes.storage}'
  'privatelink.managedhsm.azure.net'
]

resource network 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-cmk-poc'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/24'
      ]
    }
    subnets: [
      {
        name: 'snet-flex'
        properties: {
          addressPrefix: '10.0.0.0/27'
          delegations: [
            {
              name: 'flex'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
      {
        name: 'snet-private-endpoints'
        properties: {
          addressPrefix: '10.0.0.32/27'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

resource integrationSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  name: 'snet-flex'
  parent: network
}

resource endpointSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  name: 'snet-private-endpoints'
  parent: network
}

resource zones 'Microsoft.Network/privateDnsZones@2024-06-01' = [for zoneName in privateDnsNames: {
  name: zoneName
  location: 'global'
}]

resource zoneLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for (zoneName, index) in privateDnsNames: {
  name: 'link-vnet-cmk-poc'
  parent: zones[index]
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: network.id
    }
  }
}]

resource managedHsm 'Microsoft.KeyVault/managedHSMs@2024-11-01' = {
  name: 'hsmcmkpoc${suffix}'
  location: location
  sku: {
    family: 'B'
    name: 'Standard_B1'
  }
  properties: {
    tenantId: tenant().tenantId
    initialAdminObjectIds: [
      hsmAdminObjectId
    ]
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: false
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'None'
      defaultAction: 'Deny'
      // Add IP rules after provisioning. The create API rejects ipRules.
    }
  }
}

resource hsmEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-hsm-cmk-poc'
  location: location
  properties: {
    subnet: {
      id: endpointSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'managedhsm'
        properties: {
          privateLinkServiceId: managedHsm.id
          groupIds: [
            'managedhsm'
          ]
        }
      }
    ]
  }
  dependsOn: [
    network
  ]
}

resource hsmDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  name: 'default'
  parent: hsmEndpoint
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'managedhsm'
        properties: {
          privateDnsZoneId: zones[2].id
        }
      }
    ]
  }
}

output integrationSubnetId string = integrationSubnet.id
output privateEndpointSubnetId string = endpointSubnet.id
output functionsPrivateDnsZoneId string = zones[0].id
output blobPrivateDnsZoneId string = zones[1].id
output hsmName string = managedHsm.name
