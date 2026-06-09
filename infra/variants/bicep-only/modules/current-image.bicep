// Reads the currently-deployed container image of a Container App and exposes
// it as a module output. Falls back to `bootstrapImage` on 404 (first deploy).
//
// Implementation notes:
//   * Uses a dedicated user-assigned managed identity granted `Reader` on the
//     containing resource group. The role assignment is created in this module
//     so the whole thing is self-contained.
//   * The AzureCLI script retries `az containerapp show` for up to ~60s to
//     ride out AAD/RBAC propagation on the very first deploy.
//   * `forceUpdateTag` (utcNow() from caller) makes the script re-run on every
//     deployment instead of being cached.

@minLength(3)
@maxLength(12)
param namePrefix string

param location string
param appName string
param bootstrapImage string
param forceUpdateTag string

var suffix = uniqueString(resourceGroup().id, namePrefix, 'lookup')
var uamiName = '${namePrefix}-lookup-${suffix}'

resource lookupUami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiName
  location: location
}

var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'

resource readerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, lookupUami.id, readerRoleId)
  scope: resourceGroup()
  properties: {
    principalId: lookupUami.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
  }
}

resource script 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'lookup-${appName}-image'
  location: location
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${lookupUami.id}': {}
    }
  }
  dependsOn: [
    readerAssignment
  ]
  properties: {
    azCliVersion: '2.61.0'
    forceUpdateTag: forceUpdateTag
    retentionInterval: 'PT1H'
    timeout: 'PT10M'
    cleanupPreference: 'OnSuccess'
    environmentVariables: [
      { name: 'APP_NAME', value: appName }
      { name: 'RG', value: resourceGroup().name }
      { name: 'FALLBACK', value: bootstrapImage }
    ]
    scriptContent: '''
      set -euo pipefail

      # Retry to ride out RBAC propagation on first deploy.
      IMG=""
      for i in 1 2 3 4 5 6; do
        if IMG=$(az containerapp show -g "$RG" -n "$APP_NAME" \
                    --query "properties.template.containers[0].image" -o tsv 2>/dev/null); then
          break
        fi
        if ! az group show -n "$RG" >/dev/null 2>&1; then
          sleep 10
          continue
        fi
        IMG=""
        break
      done

      if [ -z "$IMG" ]; then
        IMG="$FALLBACK"
        echo "No existing app found; using bootstrap image: $IMG"
      else
        echo "Preserving current image: $IMG"
      fi

      jq -n --arg image "$IMG" '{ image: $image }' > "$AZ_SCRIPTS_OUTPUT_PATH"
    '''
  }
}

output image string = script.properties.outputs.image
