targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = 'westus2'

@description('Prefix used for naming resources. Keep it short (for example: ediscprod).')
@minLength(3)
param namePrefix string

@description('Microsoft Entra tenant ID used for app-only Graph auth.')
param tenantId string

@description('App registration (client) ID used for auth.')
param clientId string

@secure()
@description('Client secret for the app registration. Stored as a Key Vault secret when useKeyVaultReference=true.')
param clientSecret string

@description('When true, CLIENT_SECRET app setting uses a Key Vault reference.')
param useKeyVaultReference bool = true

@description('Name of the Key Vault secret that stores the app client secret.')
param keyVaultSecretName string = 'purview-client-secret'

@description('Timer schedule in NCRONTAB format.')
param timerSchedule string = '0 */30 * * * *'

@description('Container that stores cases.json.')
param configContainer string = 'ediscovery-config'

@description('Blob name for case config.')
param configBlobName string = 'cases.json'

@description('Container that stores state.json.')
param stateContainer string = 'ediscovery-state'

@description('Blob name for state data.')
param stateBlobName string = 'state.json'

@description('Container for downloaded export packages.')
param exportsContainer string = 'exports'

@description('Container used by Flex Consumption one deploy packages.')
param deploymentContainer string = 'deployment-packages'

@description('OAuth scope for Microsoft Graph token.')
param graphScope string = 'https://graph.microsoft.com/.default'

@description('OAuth scope for Purview eDiscovery download token.')
param purviewScope string = 'https://api.purview.microsoft.com/.default'

@description('OAuth scope for MicrosoftPurviewEDiscovery app (required for GCC proxy download). Set to b26e684c-5068-4120-a679-64a5d2c909d9/.default and grant eDiscovery.Download.Read with admin consent.')
param ediscoveryAppScope string = 'b26e684c-5068-4120-a679-64a5d2c909d9/.default'

@description('When true, function runtime attempts to auto-install aria2c if not already present.')
param aria2AutoInstall bool = true

@description('Path used by the function to locate/install aria2c.')
param aria2cPath string = '/tmp/aria2c'

@description('Download URL for Linux aria2c archive used during auto-install.')
param aria2DownloadUrl string = 'https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-linux-gnu-64bit-build1.tar.gz'

@allowed([
  512
  2048
  4096
])
@description('Flex Consumption instance memory size in MB.')
param instanceMemoryMB int = 2048

@minValue(1)
@maxValue(1000)
@description('Maximum number of Flex Consumption instances.')
param maximumInstanceCount int = 20

var unique = uniqueString(resourceGroup().id, namePrefix)
var storageAccountName = take(toLower(replace('${namePrefix}${unique}', '-', '')), 24)
var functionAppName = toLower('${namePrefix}-func')
var appInsightsName = '${namePrefix}-appi'
var planName = '${namePrefix}-plan'
var keyVaultName = take(toLower('${namePrefix}-${take(unique, 8)}-kv'), 24)
var clientSecretSettingValue = useKeyVaultReference ? '@Microsoft.KeyVault(SecretUri=${clientSecretSecret!.properties.secretUri})' : clientSecret

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
  }
}

resource configContainerResource 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  name: '${storage.name}/default/${configContainer}'
}

resource stateContainerResource 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  name: '${storage.name}/default/${stateContainer}'
}

resource exportsContainerResource 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  name: '${storage.name}/default/${exportsContainer}'
}

resource deploymentContainerResource 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  name: '${storage.name}/default/${deploymentContainer}'
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
  }
}

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  kind: 'linux'
  properties: {
    reserved: true
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = if (useKeyVaultReference) {
  name: keyVaultName
  location: location
  properties: {
    tenantId: tenant().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enabledForDeployment: false
    enabledForTemplateDeployment: false
    enabledForDiskEncryption: false
    publicNetworkAccess: 'Enabled'
    softDeleteRetentionInDays: 90
  }
}

resource clientSecretSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (useKeyVaultReference) {
  parent: keyVault
  name: keyVaultSecretName
  properties: {
    value: clientSecret
  }
}

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    keyVaultReferenceIdentity: 'SystemAssigned'
    functionAppConfig: {
      scaleAndConcurrency: {
        instanceMemoryMB: instanceMemoryMB
        maximumInstanceCount: maximumInstanceCount
      }
      runtime: {
        name: 'powershell'
        version: '7.4'
      }
      deployment: {
        storage: {
          type: 'blobContainer'
          value: 'https://${storage.name}.blob.${environment().suffixes.storage}/${deploymentContainer}'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
    }
    siteConfig: {
      appSettings: [
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'AzureWebJobsStorage__accountName'
          value: storage.name
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'TIMER_SCHEDULE'
          value: timerSchedule
        }
        {
          name: 'TENANT_ID'
          value: tenantId
        }
        {
          name: 'CLIENT_ID'
          value: clientId
        }
        {
          name: 'CLIENT_SECRET'
          value: clientSecretSettingValue
        }
        {
          name: 'CONFIG_CONTAINER'
          value: configContainer
        }
        {
          name: 'CONFIG_BLOB_NAME'
          value: configBlobName
        }
        {
          name: 'STATE_CONTAINER'
          value: stateContainer
        }
        {
          name: 'STATE_BLOB_NAME'
          value: stateBlobName
        }
        {
          name: 'EXPORTS_CONTAINER'
          value: exportsContainer
        }
        {
          name: 'GRAPH_SCOPE'
          value: graphScope
        }
        {
          name: 'PURVIEW_SCOPE'
          value: purviewScope
        }
        {
          name: 'EDISCOVERY_APP_SCOPE'
          value: ediscoveryAppScope
        }
        {
          name: 'ARIA2_AUTO_INSTALL'
          value: string(aria2AutoInstall)
        }
        {
          name: 'ARIA2C_PATH'
          value: aria2cPath
        }
        {
          name: 'ARIA2_DOWNLOAD_URL'
          value: aria2DownloadUrl
        }
      ]
    }
  }
  dependsOn: [
    configContainerResource
    stateContainerResource
    exportsContainerResource
    deploymentContainerResource
  ]
}

resource keyVaultSecretsUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (useKeyVaultReference) {
  name: guid(keyVault.id, functionApp.id, 'kv-secrets-user')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource storageBlobDataContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, functionApp.id, 'storage-blob-data-contributor')
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource storageQueueDataContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, functionApp.id, 'storage-queue-data-contributor')
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource storageTableDataContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, functionApp.id, 'storage-table-data-contributor')
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output functionAppName string = functionApp.name
output storageAccountName string = storage.name
output appInsightsName string = appInsights.name
output keyVaultName string = useKeyVaultReference ? keyVault.name : ''
output clientSecretSource string = useKeyVaultReference ? 'KeyVaultReference' : 'PlainAppSetting'
