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

# Use --no-wait + manual polling so a stuck ARM call can be bounded by a real
# wall-clock timeout and retried, instead of `az` hanging indefinitely.
DEPLOY_TIMEOUT_SECONDS="${DEPLOY_TIMEOUT_SECONDS:-1500}"  # 25 min per attempt
RETRIES="${RETRIES:-2}"

run_deployment() {
  local attempt="$1"
  local name="aca-infra-${attempt}-$(date +%s)"
  echo "Deploy attempt $attempt of $RETRIES (deployment name: $name) ..."

  az deployment group create \
    --name "$name" \
    --resource-group "$RG" \
    --template-file infra/main.bicep \
    --parameters "$PARAM_FILE" \
    --parameters appName="$APP" image="$IMAGE" \
    --no-wait \
    --output none

  local start=$SECONDS
  while true; do
    local state
    state=$(az deployment group show -g "$RG" -n "$name" \
              --query "properties.provisioningState" -o tsv 2>/dev/null || echo "Unknown")
    case "$state" in
      Succeeded)
        echo "Deployment succeeded."
        return 0
        ;;
      Failed|Canceled)
        echo "Deployment $state. Error details:" >&2
        az deployment group show -g "$RG" -n "$name" \
          --query "properties.error" -o json >&2 || true
        return 1
        ;;
    esac
    local elapsed=$(( SECONDS - start ))
    if [ "$elapsed" -gt "$DEPLOY_TIMEOUT_SECONDS" ]; then
      echo "Deployment exceeded ${DEPLOY_TIMEOUT_SECONDS}s wall-clock timeout; cancelling ..." >&2
      az deployment group cancel -g "$RG" -n "$name" >/dev/null 2>&1 || true
      return 124
    fi
    printf '.'
    sleep 15
  done
}

attempt=1
while ! run_deployment "$attempt"; do
  if [ "$attempt" -ge "$RETRIES" ]; then
    echo "Deployment failed after $attempt attempts." >&2
    exit 1
  fi
  attempt=$((attempt + 1))
  echo "Retrying in 30s ..."
  sleep 30
done

echo "Done."
