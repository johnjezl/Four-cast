#!/bin/bash
# =============================================================================
# Build and push AWS service images to ECR
# =============================================================================
# Mirrors gcp/push_images.sh, but for ECS Fargate + ECR.
#
# Usage:
#   bash ./aws/push_images.sh
#
# Env vars (any one of these can be overridden):
#   AWS_REGION (or AWS_DEFAULT_REGION)   default: aws configure get region
#   ENVIRONMENT                           default: dev
#
# Build context is the repo root so each image can COPY shared/ in —
# same shape as the terraform null_resource that does this on apply.
# =============================================================================
set -e

# Repo root (script lives in aws/).
cd "$(dirname "$0")/.."

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region)}}"
: "${REGION:?REGION is not set; configure AWS CLI or export AWS_REGION}"
ENVIRONMENT="${ENVIRONMENT:-dev}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
SERVICES=("device-service" "automation-service" "user-service" "analytics-service" "tuya-bridge")

echo "Region:   ${REGION}"
echo "Registry: ${REGISTRY}"
echo ""

echo "Logging in to ECR..."
aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin "$REGISTRY"

for SERVICE in "${SERVICES[@]}"; do
  IMAGE="${REGISTRY}/smarthome-${ENVIRONMENT}-${SERVICE}:latest"
  DOCKERFILE="aws/services/${SERVICE}/Dockerfile"
  echo ""
  echo "Building ${SERVICE}..."
  docker build -t "$IMAGE" -f "$DOCKERFILE" .

  echo "Pushing ${SERVICE}..."
  docker push "$IMAGE"
done

echo ""
echo "All images pushed successfully."
