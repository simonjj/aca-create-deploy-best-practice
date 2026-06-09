// One Container App. Treats `image` as a first-class parameter so the
// wrapping pipeline can supply the currently-deployed image and avoid
// clobbering it on infra-only redeploys.

@description('Container App name.')
param name string

@description('Azure region.')
param location string

@description('Managed environment resource id.')
param environmentId string

@description('ACR login server, e.g. myacr.azurecr.io.')
param acrLoginServer string

@description('User-assigned managed identity id with AcrPull on the registry.')
param acrPullIdentityId string

@description('Full image reference. Supplied by the deploy script (current image, or bootstrap on first run).')
param image string

@description('Container port.')
param targetPort int

@description('Revision suffix. Empty = derive a stable hash from the image reference.')
param revisionSuffix string = ''

@description('Environment variables for the container.')
param envVars array = []

@description('CPU cores per replica.')
param cpu string = '0.5'

@description('Memory per replica.')
param memory string = '1Gi'

@description('Min replicas.')
param minReplicas int = 1

@description('Max replicas.')
param maxReplicas int = 3

var effectiveSuffix = empty(revisionSuffix) ? take(uniqueString(image), 8) : revisionSuffix

resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: name
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${acrPullIdentityId}': {}
    }
  }
  properties: {
    environmentId: environmentId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: targetPort
        transport: 'auto'
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
      registries: [
        {
          server: acrLoginServer
          identity: acrPullIdentityId
        }
      ]
    }
    template: {
      revisionSuffix: effectiveSuffix
      containers: [
        {
          name: 'app'
          image: image
          resources: {
            cpu: json(cpu)
            memory: memory
          }
          env: envVars
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
      }
    }
  }
}

output name string = app.name
output fqdn string = app.properties.configuration.ingress.fqdn
output latestRevisionName string = app.properties.latestRevisionName
