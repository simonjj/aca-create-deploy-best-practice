// Pure-Bicep entry point. Equivalent to scripts/deploy-infra.sh but does the
// "read current image" step inside an ARM `Microsoft.Resources/deploymentScripts`
// resource, so the whole flow is one `az deployment group create`.
//
// Trade-offs vs. the wrapper-script variant:
//   + One command, no shell/PowerShell pre-step.
//   - Adds ~30-60s per deploy (script ACI spin-up).
//   - Creates a transient Microsoft.ContainerInstance + a Storage Account.
//   - First-ever deploy may need a retry while the script UAMI's `Reader`
//     RBAC propagates (the script itself retries internally).
//   - `what-if` cannot preview the resulting image — it only sees the script
//     resource, not its output.

targetScope = 'resourceGroup'

@minLength(3)
@maxLength(12)
param namePrefix string

param appName string
param location string = resourceGroup().location
param bootstrapImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
param targetPort int = 80
param revisionSuffix string = ''
param envVars array = []

@description('Bumped on every deploy to force the lookup script to re-run.')
param forceUpdateTag string = utcNow()

module platform '../../modules/environment.bicep' = {
  name: 'platform'
  params: {
    namePrefix: namePrefix
    location: location
  }
}

module lookup 'modules/current-image.bicep' = {
  name: 'current-image'
  params: {
    namePrefix: namePrefix
    location: location
    appName: appName
    bootstrapImage: bootstrapImage
    forceUpdateTag: forceUpdateTag
  }
}

module app '../../modules/containerapp.bicep' = {
  name: 'app-${appName}'
  params: {
    name: appName
    location: location
    environmentId: platform.outputs.environmentId
    acrLoginServer: platform.outputs.acrLoginServer
    acrPullIdentityId: platform.outputs.acrPullIdentityId
    image: lookup.outputs.image
    targetPort: targetPort
    revisionSuffix: revisionSuffix
    envVars: envVars
  }
}

output appFqdn string = app.outputs.fqdn
output resolvedImage string = lookup.outputs.image
