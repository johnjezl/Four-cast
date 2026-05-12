#!/bin/bash
# =============================================================================
# Build and push GCP service images to Artifact Registry
# =============================================================================
# Mirrors aws/push_images.sh, but for Cloud Run + Artifact Registry.
#
# Usage:
#   bash ./gcp/push_images.sh
#
# Env vars (any one of these can be overridden):
#   GCP_PROJECT     GCP project ID (default: `gcloud config get-value project`)
#   GCP_REGION      Artifact Registry region (default: us-central1)
#   ENVIRONMENT     smarthome env name (default: dev)
#
# Build context is the repo root so each image can COPY shared/ in —
# same shape as the terraform null_resource that does this on apply.
# =============================================================================
set -e

# Repo root (script lives in gcp/).
cd "$(dirname "$0")/.."

GCP_PROJECT="${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
: "${GCP_PROJECT:?GCP_PROJECT not set; run 'gcloud config set project <id>' or export GCP_PROJECT}"

GCP_REGION="${GCP_REGION:-us-central1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
REPO="smarthome-${ENVIRONMENT}-services"
REGISTRY="${GCP_REGION}-docker.pkg.dev"

SERVICES=("device-service" "automation-service" "user-service" "analytics-service" "tuya-bridge")

echo "Project:  ${GCP_PROJECT}"
echo "Region:   ${GCP_REGION}"
echo "Registry: ${REGISTRY}/${GCP_PROJECT}/${REPO}"
echo ""

echo "Configuring docker auth for ${REGISTRY}..."
gcloud auth configure-docker "${REGISTRY}" --quiet >/dev/null

for SERVICE in "${SERVICES[@]}"; do
  IMAGE="${REGISTRY}/${GCP_PROJECT}/${REPO}/${SERVICE}:latest"
  DOCKERFILE="gcp/services/${SERVICE}/Dockerfile"
  echo ""
  echo "Building ${SERVICE}..."
  docker build -t "$IMAGE" -f "$DOCKERFILE" .

  echo "Pushing ${SERVICE}..."
  docker push "$IMAGE"
done

echo ""
echo "All images pushed successfully."
echo "Run ./gcp/redeploy.sh to roll out new revisions."
