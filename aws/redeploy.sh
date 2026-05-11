#!/bin/bash
set -e

REGION="us-west-2"
CLUSTER="smarthome-dev-cluster"
SERVICES=("device-service" "automation-service" "user-service" "analytics-service")

for SERVICE in "${SERVICES[@]}"; do
  echo "Redeploying ${SERVICE}..."
  aws ecs update-service \
    --cluster $CLUSTER \
    --service ${SERVICE} \
    --force-new-deployment \
    --region $REGION \
    --output text \
    --query 'service.serviceName'
done

echo ""
echo "All services redeploying. Allow 2-3 minutes for health checks to pass."
