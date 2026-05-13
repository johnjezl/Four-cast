#!/bin/bash
# =============================================================================
# Set Tuya credentials in Azure Key Vault
# =============================================================================
# Updates the secret read by tuya-bridge at container start.
#
# Usage:
#   bash ./azure/set_tuya_secrets.sh                  # prompts interactively
#   TUYA_CLIENT_ID=... TUYA_CLIENT_SECRET=... \
#     bash ./azure/set_tuya_secrets.sh                # non-interactive
#
# Env vars:
#   TUYA_CLIENT_ID        Tuya Access ID (prompted if unset)
#   TUYA_CLIENT_SECRET    Tuya Access Secret (prompted if unset)
#   TUYA_REGION           Tuya datacenter: us|eu|cn|in (default: us)
#   ENVIRONMENT           smarthome env name (default: dev)
#   AZURE_RESOURCE_GROUP  Resource group (default: terraform output, then rg-smarthome-$ENVIRONMENT)
#   AZURE_KEY_VAULT_NAME  Key Vault name (default: terraform output, then discovered in resource group)
#   TUYA_SECRET_NAME      Key Vault secret name (default: tuya-credentials)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v az >/dev/null; then
  echo "ERROR: Azure CLI 'az' is required."
  exit 1
fi
if ! command -v jq >/dev/null; then
  echo "ERROR: jq is required for safe JSON encoding."
  echo "Install with: sudo apt install jq   (or brew install jq)"
  exit 1
fi

tf_output_raw() {
  (cd "$SCRIPT_DIR/terraform" && terraform output -raw "$1" 2>/dev/null) || true
}

ENVIRONMENT="${ENVIRONMENT:-dev}"
SHORT_ENV="${ENVIRONMENT:0:4}"
AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-$(tf_output_raw resource_group_name)}"
AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-rg-smarthome-${ENVIRONMENT}}"
AZURE_KEY_VAULT_NAME="${AZURE_KEY_VAULT_NAME:-$(tf_output_raw key_vault_name)}"
TUYA_SECRET_NAME="${TUYA_SECRET_NAME:-tuya-credentials}"
TUYA_REGION="${TUYA_REGION:-us}"

if [ -z "$AZURE_KEY_VAULT_NAME" ]; then
  KV_PREFIX="kvsh${SHORT_ENV}"
  AZURE_KEY_VAULT_NAME=$(az keyvault list \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --query "[?starts_with(name, '${KV_PREFIX}')].name | [0]" \
    -o tsv)
fi
: "${AZURE_KEY_VAULT_NAME:?AZURE_KEY_VAULT_NAME not set and no Key Vault discovered. Run terraform apply or export AZURE_KEY_VAULT_NAME.}"

if ! az keyvault secret show \
  --vault-name "$AZURE_KEY_VAULT_NAME" \
  --name "$TUYA_SECRET_NAME" \
  --query id \
  -o tsv >/dev/null; then
  echo "ERROR: Secret '${TUYA_SECRET_NAME}' not found in Key Vault '${AZURE_KEY_VAULT_NAME}'."
  echo "Run 'terraform apply' first so the infrastructure exists."
  exit 1
fi

if [ -z "${TUYA_CLIENT_ID:-}" ]; then
  read -r -p "Tuya Client ID (Access ID): " TUYA_CLIENT_ID
fi
if [ -z "${TUYA_CLIENT_SECRET:-}" ]; then
  read -r -s -p "Tuya Client Secret: " TUYA_CLIENT_SECRET
  echo
fi

[ -z "$TUYA_CLIENT_ID" ] && { echo "ERROR: TUYA_CLIENT_ID is required"; exit 1; }
[ -z "$TUYA_CLIENT_SECRET" ] && { echo "ERROR: TUYA_CLIENT_SECRET is required"; exit 1; }

SECRET_JSON=$(jq -n \
  --arg cid "$TUYA_CLIENT_ID" \
  --arg cs  "$TUYA_CLIENT_SECRET" \
  --arg r   "$TUYA_REGION" \
  '{client_id: $cid, client_secret: $cs, region: $r}')

echo "Updating ${TUYA_SECRET_NAME} in ${AZURE_KEY_VAULT_NAME}..."
VERSION_ID=$(az keyvault secret set \
  --vault-name "$AZURE_KEY_VAULT_NAME" \
  --name "$TUYA_SECRET_NAME" \
  --value "$SECRET_JSON" \
  --query id \
  -o tsv)

echo ""
echo "Updated. New secret version URI: ${VERSION_ID}"
echo ""
echo "Container Apps read this Key Vault secret at revision start, so roll out"
echo "tuya-bridge to pick up the new value:"
echo ""
echo "  bash ./azure/redeploy.sh tuya-bridge"
echo ""
echo "Verify the new value:"
echo "  az keyvault secret show \\"
echo "    --vault-name ${AZURE_KEY_VAULT_NAME} \\"
echo "    --name ${TUYA_SECRET_NAME} \\"
echo "    --query value -o tsv | jq ."
