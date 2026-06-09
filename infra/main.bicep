targetScope = 'resourceGroup'

@description('Short name prefix (3-12 chars, lowercase). Used to build resource names.')
@minLength(3)
@maxLength(12)
param namePrefix string

@description('Logical name of the Container App.')
param appName string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Full container image reference. The wrapping pipeline resolves this from the live resource (or falls back to a bootstrap image on first deploy).')
param image string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('Target port the container listens on. Hello-world uses 80; replace when you ship a real app.')
param targetPort int = 80

@description('Optional revision suffix (e.g. short git SHA). Empty = auto-generated from image hash.')
param revisionSuffix string = ''

@description('Environment variables surfaced to the container. Keys are managed by infra; values may reference secrets.')
param envVars array = []

module platform 'modules/environment.bicep' = {
  name: 'platform'
  params: {
    namePrefix: namePrefix
    location: location
  }
}

module app 'modules/containerapp.bicep' = {
  name: 'app-${appName}'
  params: {
    name: appName
    location: location
    environmentId: platform.outputs.environmentId
    acrLoginServer: platform.outputs.acrLoginServer
    acrPullIdentityId: platform.outputs.acrPullIdentityId
    image: image
    targetPort: targetPort
    revisionSuffix: revisionSuffix
    envVars: envVars
  }
}

output appFqdn string = app.outputs.fqdn
output appName string = app.outputs.name
output acrLoginServer string = platform.outputs.acrLoginServer
output acrName string = platform.outputs.acrName
