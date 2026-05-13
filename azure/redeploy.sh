#!/bin/bash
# =============================================================================
# Force new Azure Container Apps revisions per service
# =============================================================================
# After ./azure/push_images.sh updates the :latest tags in ACR,
# Container Apps keeps serving the previous digest until a new revision
# is created. This script forces one per service by updating each app to
# the same :latest image, which resolves the tag fresh.
#
# Usage:
#   bash ./azure/redeploy.sh
#   bash ./azure/redeploy.sh device-service tuya-bridge
#
# Env vars:
#   AZURE_RESOURCE_GROUP   Resource group (default: terraform output, then rg-smarthome-$ENVIRONMENT)
#   AZURE_ACR_NAME         ACR name (default: terraform output, then discovered in resource group)
#   AZURE_ACR_LOGIN_SERVER ACR login server (default: terraform output, then az acr show)
#   AZURE_APP_PREFIX       Container App name prefix (default: sh-${ENVIRONMENT:0:4})
#   ENVIRONMENT            smarthome env name (default: dev)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v az >/dev/null; then
  echo "ERROR: Azure CLI 'az' is required."
  exit 1
fi

tf_output_raw() {
  (cd "$SCRIPT_DIR/terraform" && terraform output -raw "$1" 2>/dev/null) || true
}

ENVIRONMENT="${ENVIRONMENT:-dev}"
SHORT_ENV="${ENVIRONMENT:0:4}"
AZURE_APP_PREFIX="${AZURE_APP_PREFIX:-sh-${SHORT_ENV}}"
AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-$(tf_output_raw resource_group_name)}"
AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-rg-smarthome-${ENVIRONMENT}}"
AZURE_ACR_NAME="${AZURE_ACR_NAME:-$(tf_output_raw container_registry_name)}"
AZURE_ACR_LOGIN_SERVER="${AZURE_ACR_LOGIN_SERVER:-$(tf_output_raw container_registry_login_server)}"

if [ -z "$AZURE_ACR_NAME" ]; then
  ACR_PREFIX="smarthome${ENVIRONMENT}"
  AZURE_ACR_NAME=$(az acr list \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --query "[?starts_with(name, '${ACR_PREFIX}')].name | [0]" \
    -o tsv)
fi
: "${AZURE_ACR_NAME:?AZURE_ACR_NAME not set and no registry discovered. Run terraform apply or export AZURE_ACR_NAME.}"

if [ -z "$AZURE_ACR_LOGIN_SERVER" ]; then
  AZURE_ACR_LOGIN_SERVER=$(az acr show \
    --name "$AZURE_ACR_NAME" \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --query loginServer \
    -o tsv)
fi
: "${AZURE_ACR_LOGIN_SERVER:?Could not resolve ACR login server.}"

DEFAULT_SERVICES=("device-service" "automation-service" "user-service" "analytics-service" "tuya-bridge")
if [ "$#" -gt 0 ]; then
  SERVICES=("$@")
else
  SERVICES=("${DEFAULT_SERVICES[@]}")
fi

patch_tuya_bridge=false

for SERVICE in "${SERVICES[@]}"; do
  APP_NAME="${AZURE_APP_PREFIX}-${SERVICE}"
  IMAGE="${AZURE_ACR_LOGIN_SERVER}/${SERVICE}:latest"

  echo "Redeploying ${APP_NAME}..."
  az containerapp update \
    --name "$APP_NAME" \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --image "$IMAGE" \
    --query properties.latestRevisionName \
    -o tsv

  if [ "$SERVICE" = "tuya-bridge" ]; then
    patch_tuya_bridge=true
  fi
done

if [ "$patch_tuya_bridge" = true ]; then
  DEVICE_FQDN=$(az containerapp show \
    --name "${AZURE_APP_PREFIX}-device-service" \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --query properties.configuration.ingress.fqdn \
    -o tsv)
  if [ -n "$DEVICE_FQDN" ]; then
    echo "Patching DEVICE_SERVICE_URL on ${AZURE_APP_PREFIX}-tuya-bridge..."
    az containerapp update \
      --name "${AZURE_APP_PREFIX}-tuya-bridge" \
      --resource-group "$AZURE_RESOURCE_GROUP" \
      --set-env-vars "DEVICE_SERVICE_URL=https://${DEVICE_FQDN}" \
      --query properties.latestRevisionName \
      -o tsv
  else
    echo "WARNING: could not resolve device-service FQDN; tuya-bridge DEVICE_SERVICE_URL was not patched."
  fi
fi

echo ""
echo "Redeploy complete. Allow ~1 minute for new revisions to pass health checks."
