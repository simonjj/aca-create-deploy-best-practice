#!/usr/bin/env bash
# Builds the app, pushes to ACR by digest, and rolls a new revision.
# No Bicep involved.
#
# Required env: RG
# Optional env: APP (default: api), TAG (default: git short SHA or timestamp),
#               CONTEXT (default: src/$APP)

set -euo pipefail

: "${RG:?Set RG to the target resource group name}"
APP="${APP:-api}"
CONTEXT="${CONTEXT:-src/$APP}"

if [[ -z "${TAG:-}" ]]; then
  if git rev-parse --short HEAD >/dev/null 2>&1; then
    TAG=$(git rev-parse --short HEAD)
  else
    TAG=$(date -u +%Y%m%d-%H%M%S)
  fi
fi

ACR=$(az containerapp show -g "$RG" -n "$APP" \
        --query "properties.configuration.registries[0].server" -o tsv \
      | cut -d. -f1)

if [[ -z "$ACR" ]]; then
  echo "Could not discover ACR from Container App $APP. Run deploy-infra.sh first." >&2
  exit 1
fi

echo "Building & pushing $APP:$TAG to $ACR ..."
az acr build -r "$ACR" -t "$APP:$TAG" "$CONTEXT" >/dev/null

DIGEST=$(az acr repository show -n "$ACR" --image "$APP:$TAG" --query "digest" -o tsv)
REF="$ACR.azurecr.io/$APP@$DIGEST"
echo "Image digest reference: $REF"

echo "Rolling new revision ..."
az containerapp update \
  -g "$RG" -n "$APP" \
  --image "$REF" \
  --revision-suffix "sha-$TAG" \
  --output table

FQDN=$(az containerapp show -g "$RG" -n "$APP" --query properties.configuration.ingress.fqdn -o tsv)
echo "App live at: https://$FQDN"
