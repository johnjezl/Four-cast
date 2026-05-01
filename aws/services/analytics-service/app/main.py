"""
Analytics Service
=================
Provides metrics, SLOs, and developer experience analytics.

Textbook Reference:
- Ch. 6-7: Developer Experience Metrics
- Ch. 7: Platform Maturity Model

AWS Services Used:
- Timestream: Time-series device metrics storage
- CloudWatch: Platform operational metrics
"""

import os
import json
import logging
from datetime import datetime, timedelta
from typing import Optional
from contextlib import asynccontextmanager
from collections import defaultdict

from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
import boto3
from botocore.exceptions import ClientError

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Configuration
TIMESTREAM_DATABASE = os.getenv("TIMESTREAM_DATABASE", "")
TIMESTREAM_TABLE = os.getenv("TIMESTREAM_TABLE", "device_telemetry")
AWS_REGION = os.getenv("AWS_REGION", "us-east-1")


# =============================================================================
# Data Models
# =============================================================================

class SLODefinition(BaseModel):
    """Service Level Objective definition."""
    id: str
    name: str
    description: str
    metric: str
    target: float
    window: str = "30d"  # 30 days rolling window
    operator: str = "gte"  # gte, lte, eq


class SLOStatus(BaseModel):
    """Current SLO status."""
    slo_id: str
    name: str
    target: float
    current: float
    status: str  # healthy, warning, breached
    error_budget_remaining: float


class DevExMetric(BaseModel):
    """Developer Experience metric."""
    id: str
    name: str
    category: str  # onboarding, deployment, debugging
    value: float
    unit: str
    measured_at: datetime = Field(default_factory=datetime.utcnow)


class PlatformMaturityAssessment(BaseModel):
    """
    Platform Maturity Model assessment.
    
    Textbook Reference: Ch. 7 - Platform Maturity Model
    Levels: Provisional (1), Operational (2), Scalable (3), Optimizing (4)
    """
    dimension: str
    level: int
    score: float
    evidence: list[str]
    recommendations: list[str]


# =============================================================================
# In-Memory Storage & Mock Data
# =============================================================================

# SLO Definitions
slos_db: dict[str, SLODefinition] = {
    "device-registration-latency": SLODefinition(
        id="device-registration-latency",
        name="Device Registration Latency",
        description="Time to register a new device should be under 2 seconds",
        metric="device.registration.latency_p95",
        target=2000,  # milliseconds
        operator="lte"
    ),
    "api-availability": SLODefinition(
        id="api-availability",
        name="API Availability",
        description="API should be available 99.5% of the time",
        metric="api.availability",
        target=99.5,
        operator="gte"
    ),
    "device-sync-success": SLODefinition(
        id="device-sync-success",
        name="Device Sync Success Rate",
        description="Device state sync should succeed 99% of the time",
        metric="device.sync.success_rate",
        target=99.0,
        operator="gte"
    ),
    "time-to-first-device": SLODefinition(
        id="time-to-first-device",
        name="Time to First Device",
        description="New users should register their first device within 5 minutes",
        metric="devex.time_to_first_device",
        target=300,  # seconds
        operator="lte"
    )
}

# Simulated current metrics
current_metrics = {
    "device.registration.latency_p95": 850,  # ms
    "api.availability": 99.8,  # %
    "device.sync.success_rate": 99.5,  # %
    "devex.time_to_first_device": 180,  # seconds
}

# DevEx Metrics history
devex_metrics: list[DevExMetric] = []

# Platform usage stats
usage_stats = defaultdict(int)


# =============================================================================
# Timestream Integration
# =============================================================================

def get_timestream_client():
    if TIMESTREAM_DATABASE:
        return boto3.client('timestream-query', region_name=AWS_REGION)
    return None


async def query_device_metrics(device_id: str, metric: str, hours: int = 24) -> list:
    """Query device metrics from Timestream."""
    client = get_timestream_client()
    if not client:
        # Return mock data
        return [
            {"time": datetime.utcnow() - timedelta(hours=i), "value": 75 + (i % 10)}
            for i in range(hours)
        ]
    
    try:
        query = f"""
            SELECT time, measure_value::double as value
            FROM "{TIMESTREAM_DATABASE}"."{TIMESTREAM_TABLE}"
            WHERE device_id = '{device_id}'
            AND measure_name = '{metric}'
            AND time > ago({hours}h)
            ORDER BY time DESC
        """
        response = client.query(QueryString=query)
        return [
            {"time": row['Data'][0]['ScalarValue'], "value": float(row['Data'][1]['ScalarValue'])}
            for row in response['Rows']
        ]
    except ClientError as e:
        logger.error(f"Timestream query error: {e}")
        return []


# =============================================================================
# Application
# =============================================================================

@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Analytics Service starting...")
    logger.info(f"Timestream DB: {TIMESTREAM_DATABASE or 'Not configured (using mock data)'}")
    yield
    logger.info("Analytics Service shutting down...")


app = FastAPI(
    title="Analytics Service",
    description="Metrics, SLOs, and Developer Experience Analytics",
    version="1.0.0",
    lifespan=lifespan
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# =============================================================================
# Endpoints
# =============================================================================

@app.get("/health")
async def health():
    return {"status": "healthy", "service": "analytics-service"}


@app.get("/api/v1/analytics/info")
async def info():
    return {
        "service": "analytics-service",
        "timestream_configured": bool(TIMESTREAM_DATABASE),
        "slos_defined": len(slos_db),
        "metrics_tracked": len(current_metrics)
    }


# =============================================================================
# SLO Endpoints
# =============================================================================

@app.get("/api/v1/analytics/slos", tags=["SLOs"])
async def list_slos():
    """
    List all defined SLOs.
    
    Textbook Reference: Ch. 6-7 - SLOs for platform health
    """
    return {"slos": list(slos_db.values())}


@app.get("/api/v1/analytics/slos/status", tags=["SLOs"])
async def get_slo_status():
    """Get current status of all SLOs."""
    statuses = []
    
    for slo in slos_db.values():
        current = current_metrics.get(slo.metric, 0)
        
        if slo.operator == "gte":
            met = current >= slo.target
            error_budget = max(0, current - slo.target) / slo.target * 100
        else:
            met = current <= slo.target
            error_budget = max(0, slo.target - current) / slo.target * 100
        
        if met:
            status = "healthy"
        elif error_budget > 0.5:
            status = "warning"
        else:
            status = "breached"
        
        statuses.append(SLOStatus(
            slo_id=slo.id,
            name=slo.name,
            target=slo.target,
            current=current,
            status=status,
            error_budget_remaining=min(100, error_budget)
        ))
    
    return {"slo_status": statuses}


@app.get("/api/v1/analytics/slos/{slo_id}", tags=["SLOs"])
async def get_slo(slo_id: str):
    if slo_id not in slos_db:
        raise HTTPException(status_code=404, detail="SLO not found")
    return slos_db[slo_id]


# =============================================================================
# Developer Experience Metrics
# =============================================================================

@app.get("/api/v1/analytics/devex", tags=["DevEx"])
async def get_devex_metrics():
    """
    Get Developer Experience metrics.
    
    Textbook Reference: Ch. 6-7 - DevEx metrics for platform success
    """
    return {
        "metrics": {
            "time_to_first_device": {
                "value": 180,
                "unit": "seconds",
                "target": 300,
                "status": "healthy"
            },
            "api_docs_satisfaction": {
                "value": 4.2,
                "unit": "rating",
                "target": 4.0,
                "status": "healthy"
            },
            "deployment_frequency": {
                "value": 12,
                "unit": "deploys/week",
                "target": 10,
                "status": "healthy"
            },
            "mean_time_to_recovery": {
                "value": 15,
                "unit": "minutes",
                "target": 30,
                "status": "healthy"
            },
            "golden_path_adoption": {
                "value": 85,
                "unit": "percent",
                "target": 80,
                "status": "healthy"
            }
        }
    }


@app.post("/api/v1/analytics/devex/track", tags=["DevEx"])
async def track_devex_event(metric_name: str, value: float, category: str = "general"):
    """Track a DevEx metric."""
    metric = DevExMetric(
        id=f"metric-{len(devex_metrics) + 1}",
        name=metric_name,
        category=category,
        value=value,
        unit="custom"
    )
    devex_metrics.append(metric)
    return {"tracked": metric}


# =============================================================================
# Platform Maturity Assessment
# =============================================================================

@app.get("/api/v1/analytics/maturity", tags=["Maturity"])
async def get_maturity_assessment():
    """
    Platform Maturity Model assessment.
    
    Textbook Reference: Ch. 7 - Platform Maturity Model
    """
    return {
        "overall_level": 2,
        "overall_score": 2.4,
        "dimensions": [
            PlatformMaturityAssessment(
                dimension="Infrastructure",
                level=3,
                score=3.0,
                evidence=[
                    "Infrastructure as Code (Terraform)",
                    "Automated deployments via CI/CD",
                    "Container orchestration (ECS Fargate)"
                ],
                recommendations=[
                    "Add multi-region deployment",
                    "Implement chaos engineering"
                ]
            ),
            PlatformMaturityAssessment(
                dimension="Developer Experience",
                level=2,
                score=2.5,
                evidence=[
                    "Self-service API for device registration",
                    "API documentation available",
                    "Golden Path templates for automations"
                ],
                recommendations=[
                    "Add interactive API explorer",
                    "Implement developer portal",
                    "Add more Golden Path templates"
                ]
            ),
            PlatformMaturityAssessment(
                dimension="Observability",
                level=2,
                score=2.0,
                evidence=[
                    "Centralized logging (CloudWatch)",
                    "Basic SLO tracking",
                    "Time-series metrics (Timestream)"
                ],
                recommendations=[
                    "Add distributed tracing",
                    "Implement SLO dashboards",
                    "Add alerting automation"
                ]
            ),
            PlatformMaturityAssessment(
                dimension="Security",
                level=2,
                score=2.5,
                evidence=[
                    "API key authentication",
                    "Secrets management (Secrets Manager)",
                    "Security scanning in CI/CD"
                ],
                recommendations=[
                    "Add OAuth2/OIDC support",
                    "Implement RBAC",
                    "Add audit logging"
                ]
            )
        ]
    }


# =============================================================================
# Device Analytics
# =============================================================================

@app.get("/api/v1/analytics/devices/{device_id}/metrics", tags=["Device Analytics"])
async def get_device_metrics(
    device_id: str,
    metric: str = Query("brightness", description="Metric to query"),
    hours: int = Query(24, ge=1, le=168)
):
    """Get device metrics from Timestream."""
    data = await query_device_metrics(device_id, metric, hours)
    return {
        "device_id": device_id,
        "metric": metric,
        "period_hours": hours,
        "data": data
    }


@app.get("/api/v1/analytics/devices/summary", tags=["Device Analytics"])
async def get_devices_summary():
    """Get summary analytics for all devices."""
    return {
        "total_devices": 5,
        "online_devices": 4,
        "offline_devices": 1,
        "commands_today": 127,
        "automations_triggered": 23,
        "avg_response_time_ms": 245
    }


# =============================================================================
# Usage Statistics
# =============================================================================

@app.get("/api/v1/analytics/usage", tags=["Usage"])
async def get_usage_stats():
    """Get platform usage statistics."""
    return {
        "api_calls_24h": 1523,
        "unique_users_24h": 12,
        "devices_registered_7d": 8,
        "automations_created_7d": 5,
        "top_endpoints": [
            {"endpoint": "/api/v1/device/devices", "calls": 450},
            {"endpoint": "/api/v1/device/devices/{id}/state", "calls": 320},
            {"endpoint": "/api/v1/automation/rules", "calls": 180}
        ]
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8004)
