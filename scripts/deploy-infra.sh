#!/usr/bin/env bash
# Deploys the infrastructure (ACA env, ACR, identity, Container App).
#
# Crucial step: resolves the currently-deployed image on the Container App
# BEFORE running Bicep, so an infra-only deploy doesn't flip the running
# app back to the bootstrap (hello-world) image.
#
# Required env: RG
# Optional env: APP (default: api), LOCATION (default: eastus2),
#               BOOTSTRAP_IMAGE (default: hello-world),
#               PARAM_FILE (default: infra/main.bicepparam)

set -euo pipefail

: "${RG:?Set RG to the target resource group name}"
APP="${APP:-api}"
LOCATION="${LOCATION:-eastus2}"
BOOTSTRAP_IMAGE="${BOOTSTRAP_IMAGE:-mcr.microsoft.com/azuredocs/containerapps-helloworld:latest}"
PARAM_FILE="${PARAM_FILE:-infra/main.bicepparam}"

az group show -n "$RG" >/dev/null 2>&1 \
  || az group create -n "$RG" -l "$LOCATION" >/dev/null

echo "Resolving current image for $APP in $RG ..."
IMAGE=$(az containerapp show -g "$RG" -n "$APP" \
          --query "properties.template.containers[0].image" -o tsv 2>/dev/null \
          || true)

if [[ -z "${IMAGE:-}" ]]; then
  IMAGE="$BOOTSTRAP_IMAGE"
  echo "  No existing app found. Using bootstrap image: $IMAGE"
else
  echo "  Preserving current image: $IMAGE"
fi

echo "Running what-if ..."
az deployment group what-if \
  --resource-group "$RG" \
  --template-file infra/main.bicep \
  --parameters "$PARAM_FILE" \
  --parameters appName="$APP" image="$IMAGE"

echo "Deploying ..."
az deployment group create \
  --resource-group "$RG" \
  --template-file infra/main.bicep \
  --parameters "$PARAM_FILE" \
  --parameters appName="$APP" image="$IMAGE" \
  --output table

echo "Done."
