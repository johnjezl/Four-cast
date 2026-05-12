#!/bin/bash
# =============================================================================
# Force new Cloud Run revisions per service
# =============================================================================
# After `./gcp/push_images.sh` updates the :latest tags in Artifact
# Registry, Cloud Run keeps serving the previous digest until a new
# revision is created. This script forces one per service by re-deploying
# the same `:latest` image — gcloud resolves the tag fresh, so the new
# revision pulls the new digest.
#
# Usage:
#   bash ./gcp/redeploy.sh
#
# Env vars:
#   GCP_PROJECT     GCP project ID (default: `gcloud config get-value project`)
#   GCP_REGION      Cloud Run region (default: us-central1)
#   ENVIRONMENT     smarthome env name (default: dev)
#
# tuya-bridge note: this script re-deploys it like every other service,
# which means the new revision will be created from the declared
# template — which doesn't contain DEVICE_SERVICE_URL (managed by the
# null_resource patch). Either:
#   (a) follow up with `terraform apply` so the patch re-runs, or
#   (b) drop tuya-bridge from this script and redeploy it via
#       `terraform taint module.cloud_run.google_cloud_run_v2_service.tuya_bridge
#        && terraform apply`, which forces the patch too.
# We do (a): this script triggers the redeploy, README + the printed
# tail message remind you to apply afterward.
# =============================================================================
set -e

GCP_PROJECT="${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
: "${GCP_PROJECT:?GCP_PROJECT not set; run 'gcloud config set project <id>' or export GCP_PROJECT}"

GCP_REGION="${GCP_REGION:-us-central1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
REPO="smarthome-${ENVIRONMENT}-services"
REGISTRY="${GCP_REGION}-docker.pkg.dev"

SERVICES=("device-service" "automation-service" "user-service" "analytics-service" "tuya-bridge")

for SERVICE in "${SERVICES[@]}"; do
  CLOUD_RUN_NAME="smarthome-${ENVIRONMENT}-${SERVICE}"
  IMAGE="${REGISTRY}/${GCP_PROJECT}/${REPO}/${SERVICE}:latest"
  echo "Redeploying ${CLOUD_RUN_NAME}..."
  gcloud run services update "${CLOUD_RUN_NAME}" \
    --region="${GCP_REGION}" \
    --project="${GCP_PROJECT}" \
    --image="${IMAGE}" \
    --quiet \
    --format='value(status.latestReadyRevisionName)'
done

echo ""
echo "All services redeploying. Allow ~1 minute for new revisions to pass health checks."
echo ""
echo "tuya-bridge's new revision will be missing DEVICE_SERVICE_URL until you run"
echo "'terraform apply' (the null_resource patch re-fires via replace_triggered_by)."
