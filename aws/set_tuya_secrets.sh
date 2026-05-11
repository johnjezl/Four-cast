#!/bin/bash
# =============================================================================
# Set Tuya credentials in AWS Secrets Manager
# =============================================================================
# Updates the secret read by both Lambda functions (tuya-poller and
# tuya-command) at invocation time.
#
# Usage:
#   bash ./aws/set_tuya_secrets.sh                  # prompts interactively
#   TUYA_CLIENT_ID=... TUYA_CLIENT_SECRET=... \
#     bash ./aws/set_tuya_secrets.sh                # non-interactive
#
# Env vars:
#   TUYA_CLIENT_ID       Tuya Access ID (prompted if unset)
#   TUYA_CLIENT_SECRET   Tuya Access Secret (prompted if unset)
#   TUYA_REGION          Tuya datacenter: us|eu|cn|in (default: us)
#   ENVIRONMENT          smarthome env name (default: dev)
#   AWS_REGION           AWS region (default: from `aws configure get region`)
# =============================================================================
set -e

cd "$(dirname "$0")"

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region)}}"
: "${REGION:?REGION is not set; configure AWS CLI or export AWS_REGION}"

ENVIRONMENT="${ENVIRONMENT:-dev}"
SECRET_NAME="smarthome-${ENVIRONMENT}-tuya-credentials"
TUYA_REGION="${TUYA_REGION:-us}"

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required for safe JSON encoding."
  echo "Install with: sudo apt install jq   (or brew install jq)"
  exit 1
fi

if ! aws secretsmanager describe-secret \
    --secret-id "$SECRET_NAME" \
    --region "$REGION" &>/dev/null; then
  echo "ERROR: Secret '$SECRET_NAME' not found in region '$REGION'."
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

echo "Updating ${SECRET_NAME} in ${REGION}..."
VERSION_ID=$(aws secretsmanager put-secret-value \
  --region "$REGION" \
  --secret-id "$SECRET_NAME" \
  --secret-string "$SECRET_JSON" \
  --output text \
  --query 'VersionId')

echo ""
echo "Updated. New secret version: ${VERSION_ID}"
echo ""
echo "The Lambda functions read this secret on each invocation, so changes"
echo "take effect within ~15 min as warm Lambda containers cycle out."
echo ""
echo "Verify the new value:"
echo "  aws secretsmanager get-secret-value \\"
echo "    --region ${REGION} \\"
echo "    --secret-id ${SECRET_NAME} \\"
echo "    --query SecretString --output text | jq ."
echo ""
echo "Force an immediate Lambda refresh (touches config to invalidate warm containers):"
echo "  for FN in smarthome-${ENVIRONMENT}-tuya-poller smarthome-${ENVIRONMENT}-tuya-command; do"
echo "    aws lambda update-function-configuration --region ${REGION} \\"
echo "      --function-name \$FN --description \"refresh-\$(date +%s)\" >/dev/null"
echo "  done"
