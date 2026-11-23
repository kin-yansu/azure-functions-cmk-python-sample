targetScope = 'resourceGroup'

param location string = resourceGroup().location

@description('既存の Flex Consumption VNet 統合用サブネットのリソース ID。')
@minLength(1)
param integrationSubnetId string

@description('既存の Private Endpoint 用サブネットのリソース ID。')
@minLength(1)
param privateEndpointSubnetId string

@description('既存 privatelink.azurewebsites.net ゾーンのリソース ID。')
@minLength(1)
param functionsPrivateDnsZoneId string

@description('既存 privatelink.blob.core.windows.net ゾーンのリソース ID。')
@minLength(1)
param blobPrivateDnsZoneId string

@description('有効化済み Managed HSM の名前。')
@minLength(1)
param hsmName string

@description('A256KW 用の検証鍵の名前。')
@minLength(1)
param hsmKeyName string

@description('新規書き込みに使う検証鍵の 32 文字のバージョン ID。')
@minLength(32)
@maxLength(32)
param hsmKeyVersion string

@description('既存の Entra API アプリ登録のアプリケーション (クライアント) ID。')
@minLength(36)
@maxLength(36)
param apiClientId string

@description('呼び出し元トークンの aud。v2 トークンの既定の想定は API のクライアント ID。')
param apiAudience string = apiClientId

@description('許可する呼び出し元サービスプリンシパルのオブジェクト ID。')
@minLength(36)
@maxLength(36)
param callerPrincipalId string

var suffix = uniqueString(resourceGroup().id)
var appName = 'func-cmk-poc-${suffix}'
var deploymentContainerName = 'function-packages'
var documentContainerName = 'documents'
var storageBlobDataOwnerRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')

resource appIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-cmk-poc-${suffix}'
  location: location
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'stcmkpoc${suffix}'
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Disabled'
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  name: 'default'
  parent: storage
}

resource packages 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  name: deploymentContainerName
  parent: blobService
  properties: {
    publicAccess: 'None'
  }
}

resource documents 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  name: documentContainerName
  parent: blobService
  properties: {
    publicAccess: 'None'
  }
}

// PoC: ホスト用のアカウント単位の Blob 権限をデプロイ・文書保存でも共用。
resource storageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, appIdentity.id, storageBlobDataOwnerRoleId)
  scope: storage
  properties: {
    roleDefinitionId: storageBlobDataOwnerRoleId
    principalId: appIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource blobEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-blob-cmk-poc-${suffix}'
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'blob'
        properties: {
          privateLinkServiceId: storage.id
          groupIds: [
            'blob'
          ]
        }
      }
    ]
  }
}

resource blobDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  name: 'default'
  parent: blobEndpoint
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob'
        properties: {
          privateDnsZoneId: blobPrivateDnsZoneId
        }
      }
    ]
  }
}

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'plan-cmk-poc-${suffix}'
  location: location
  kind: 'functionapp'
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  properties: {
    reserved: true
  }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: appName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${appIdentity.id}': {}
    }
  }
  properties: {
    serverFarmId: plan.id
    virtualNetworkSubnetId: integrationSubnetId
    publicNetworkAccess: 'Disabled'
    httpsOnly: true
    functionAppConfig: {
      runtime: {
        name: 'python'
        version: '3.12'
      }
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${packages.name}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: appIdentity.id
          }
        }
      }
      scaleAndConcurrency: {
        instanceMemoryMB: 512
        maximumInstanceCount: 40
      }
    }
    siteConfig: {
      minTlsVersion: '1.2'
      appSettings: [
        {
          name: 'AzureWebJobsStorage__accountName'
          value: storage.name
        }
        {
          name: 'AzureWebJobsStorage__credential'
          value: 'managedidentity'
        }
        {
          name: 'AzureWebJobsStorage__clientId'
          value: appIdentity.properties.clientId
        }
        {
          name: 'DOCUMENT_MANAGED_IDENTITY_CLIENT_ID'
          value: appIdentity.properties.clientId
        }
        {
          name: 'DOCUMENT_BLOB_URL'
          value: storage.properties.primaryEndpoints.blob
        }
        {
          name: 'DOCUMENT_CONTAINER'
          value: documents.name
        }
        {
          name: 'HSM_URL'
          value: 'https://${hsmName}.managedhsm.azure.net'
        }
        {
          name: 'HSM_KEY_NAME'
          value: hsmKeyName
        }
        {
          name: 'HSM_KEY_VERSION'
          value: hsmKeyVersion
        }
      ]
    }
  }
  dependsOn: [
    blobDns
    storageRole
  ]
}

resource auth 'Microsoft.Web/sites/config@2022-09-01' = {
  name: 'authsettingsV2'
  parent: functionApp
  properties: {
    platform: {
      enabled: true
    }
    globalValidation: {
      requireAuthentication: true
      unauthenticatedClientAction: 'Return401'
    }
    httpSettings: {
      requireHttps: true
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: apiClientId
          openIdIssuer: 'https://login.microsoftonline.com/${tenant().tenantId}/v2.0'
        }
        validation: {
          allowedAudiences: [
            apiAudience
          ]
          defaultAuthorizationPolicy: {
            allowedPrincipals: {
              identities: [
                callerPrincipalId
              ]
            }
          }
        }
      }
    }
  }
}

resource functionEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-app-cmk-poc-${suffix}'
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'sites'
        properties: {
          privateLinkServiceId: functionApp.id
          groupIds: [
            'sites'
          ]
        }
      }
    ]
  }
  dependsOn: [
    auth
  ]
}

resource functionDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  name: 'default'
  parent: functionEndpoint
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'sites'
        properties: {
          privateDnsZoneId: functionsPrivateDnsZoneId
        }
      }
    ]
  }
}

output functionAppName string = functionApp.name
output functionUrl string = 'https://${functionApp.properties.defaultHostName}'
output storageAccountName string = storage.name
output runtimePrincipalId string = appIdentity.properties.principalId
