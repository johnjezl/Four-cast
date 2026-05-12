#!/bin/bash
# =============================================================================
# Set Tuya credentials in GCP Secret Manager
# =============================================================================
# Updates the secret read by tuya-bridge at container start.
#
# Usage:
#   bash ./gcp/set_tuya_secrets.sh                  # prompts interactively
#   TUYA_CLIENT_ID=... TUYA_CLIENT_SECRET=... \
#     bash ./gcp/set_tuya_secrets.sh                # non-interactive
#
# Env vars:
#   TUYA_CLIENT_ID       Tuya Access ID (prompted if unset)
#   TUYA_CLIENT_SECRET   Tuya Access Secret (prompted if unset)
#   TUYA_REGION          Tuya datacenter: us|eu|cn|in (default: us)
#   ENVIRONMENT          smarthome env name (default: dev)
#   GCP_PROJECT          GCP project ID (default: `gcloud config get-value project`)
# =============================================================================
set -e

cd "$(dirname "$0")"

GCP_PROJECT="${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
: "${GCP_PROJECT:?GCP_PROJECT not set; run 'gcloud config set project <id>' or export GCP_PROJECT}"

ENVIRONMENT="${ENVIRONMENT:-dev}"
SECRET_NAME="smarthome-${ENVIRONMENT}-tuya-credentials"
TUYA_REGION="${TUYA_REGION:-us}"

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required for safe JSON encoding."
  echo "Install with: sudo apt install jq   (or brew install jq)"
  exit 1
fi

if ! gcloud secrets describe "$SECRET_NAME" \
    --project="$GCP_PROJECT" &>/dev/null; then
  echo "ERROR: Secret '$SECRET_NAME' not found in project '$GCP_PROJECT'."
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

echo "Adding new version to ${SECRET_NAME} in ${GCP_PROJECT}..."
VERSION_NAME=$(printf '%s' "$SECRET_JSON" | gcloud secrets versions add "$SECRET_NAME" \
  --project="$GCP_PROJECT" \
  --data-file=- \
  --format='value(name)')

echo ""
echo "Updated. New secret version: ${VERSION_NAME}"
echo ""
echo "Cloud Run reads this secret at container start, so the running"
echo "tuya-bridge revision will keep serving the old value. Roll out the new"
echo "value by forcing a new revision:"
echo ""
echo "  gcloud run services update smarthome-${ENVIRONMENT}-tuya-bridge \\"
echo "    --project=${GCP_PROJECT} \\"
echo "    --region=\$GCP_REGION \\"
echo "    --image=\$GCP_REGION-docker.pkg.dev/${GCP_PROJECT}/smarthome-${ENVIRONMENT}-services/tuya-bridge:latest"
echo ""
echo "  # …then follow up with 'terraform apply' so the DEVICE_SERVICE_URL"
echo "  # patch re-fires against the new revision."
echo ""
echo "Verify the new value:"
echo "  gcloud secrets versions access latest \\"
echo "    --project=${GCP_PROJECT} \\"
echo "    --secret=${SECRET_NAME} | jq ."
