#!/bin/bash
# =============================================================================
# Build and push Azure service images to Azure Container Registry
# =============================================================================
# Mirrors the existing image-push flow, but for Container Apps + ACR.
#
# Usage:
#   bash ./azure/push_images.sh
#   bash ./azure/push_images.sh device-service tuya-bridge
#
# Env vars:
#   AZURE_RESOURCE_GROUP  Resource group (default: terraform output, then rg-smarthome-$ENVIRONMENT)
#   AZURE_ACR_NAME        ACR name (default: terraform output, then discovered in resource group)
#   AZURE_ACR_LOGIN_SERVER ACR login server (default: terraform output, then az acr show)
#   ENVIRONMENT           smarthome env name (default: dev)
#
# Build context is the repo root so each image can COPY shared/ in -
# same shape as the terraform null_resource that does this on apply.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v az >/dev/null; then
  echo "ERROR: Azure CLI 'az' is required."
  exit 1
fi
if ! command -v docker >/dev/null; then
  echo "ERROR: docker is required."
  exit 1
fi

tf_output_raw() {
  (cd "$SCRIPT_DIR/terraform" && terraform output -raw "$1" 2>/dev/null) || true
}

ENVIRONMENT="${ENVIRONMENT:-dev}"
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

echo "Resource group: ${AZURE_RESOURCE_GROUP}"
echo "Registry:       ${AZURE_ACR_LOGIN_SERVER}"
echo ""

echo "Logging in to ${AZURE_ACR_NAME}..."
az acr login --name "$AZURE_ACR_NAME" >/dev/null

for SERVICE in "${SERVICES[@]}"; do
  IMAGE="${AZURE_ACR_LOGIN_SERVER}/${SERVICE}:latest"
  DOCKERFILE="azure/services/${SERVICE}/Dockerfile"

  if [ ! -f "$DOCKERFILE" ]; then
    echo "ERROR: unknown service '${SERVICE}' (missing ${DOCKERFILE})."
    exit 2
  fi

  echo ""
  echo "Building ${SERVICE}..."
  docker build -t "$IMAGE" -f "$DOCKERFILE" .

  echo "Pushing ${SERVICE}..."
  docker push "$IMAGE"
done

echo ""
echo "All images pushed successfully."
echo "Run ./azure/redeploy.sh to roll out new Container Apps revisions."
