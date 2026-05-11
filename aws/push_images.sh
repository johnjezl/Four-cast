#!/bin/bash
set -e

REGION="us-west-2"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
SERVICES=("device-service" "automation-service" "user-service" "analytics-service")

echo "Logging in to ECR..."
aws ecr get-login-password --region $REGION | \
  docker login --username AWS --password-stdin $REGISTRY

for SERVICE in "${SERVICES[@]}"; do
  IMAGE="${REGISTRY}/smarthome-dev-${SERVICE}:latest"
  echo ""
  echo "Building ${SERVICE}..."
  docker build -t $IMAGE services/${SERVICE}

  echo "Pushing ${SERVICE}..."
  docker push $IMAGE
done

echo ""
echo "All images pushed successfully."