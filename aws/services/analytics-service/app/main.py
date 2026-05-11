"""
Analytics Service
=================
Provides metrics, SLOs, and developer-experience analytics.

Storage: Postgres for tracked DevEx metrics. SLOs, current metrics,
maturity dashboards, and other static/mock data remain in-memory.
"""

import os
import uuid
import socket
import logging
from datetime import datetime, timedelta
from typing import Optional
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Depends, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from sqlalchemy import desc
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import Field, SQLModel, select
import boto3
from botocore.exceptions import ClientError

from .db import engine, get_session, init_db

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO").upper())
logger = logging.getLogger(__name__)

TIMESTREAM_DATABASE = os.getenv("TIMESTREAM_DATABASE", "")
TIMESTREAM_TABLE = os.getenv("TIMESTREAM_TABLE", "device_telemetry")
AWS_REGION = os.getenv("AWS_REGION", "us-east-1")


# =============================================================================
# Models
# =============================================================================

class SLODefinition(BaseModel):
    id: str
    name: str
    description: str
    metric: str
    target: float
    window: str = "30d"
    operator: str = "gte"


class SLOStatus(BaseModel):
    slo_id: str
    name: str
    target: float
    current: float
    status: str
    error_budget_remaining: float


class DevExMetric(SQLModel, table=True):
    __tablename__ = "devex_metrics"
    id: str = Field(primary_key=True)
    name: str = Field(index=True)
    category: str = Field(default="general", index=True)
    value: float
    unit: str = "custom"
    measured_at: datetime = Field(default_factory=datetime.utcnow, index=True)


class PlatformMaturityAssessment(BaseModel):
    dimension: str
    level: int
    score: float
    evidence: list[str]
    recommendations: list[str]


# =============================================================================
# Static / Mock Data
# =============================================================================

slos_db: dict[str, SLODefinition] = {
    "device-registration-latency": SLODefinition(
        id="device-registration-latency",
        name="Device Registration Latency",
        description="Time to register a new device should be under 2 seconds",
        metric="device.registration.latency_p95",
        target=2000,
        operator="lte",
    ),
    "api-availability": SLODefinition(
        id="api-availability",
        name="API Availability",
        description="API should be available 99.5% of the time",
        metric="api.availability",
        target=99.5,
        operator="gte",
    ),
    "device-sync-success": SLODefinition(
        id="device-sync-success",
        name="Device Sync Success Rate",
        description="Device state sync should succeed 99% of the time",
        metric="device.sync.success_rate",
        target=99.0,
        operator="gte",
    ),
    "time-to-first-device": SLODefinition(
        id="time-to-first-device",
        name="Time to First Device",
        description="New users should register their first device within 5 minutes",
        metric="devex.time_to_first_device",
        target=300,
        operator="lte",
    ),
}

current_metrics = {
    "device.registration.latency_p95": 850,
    "api.availability": 99.8,
    "device.sync.success_rate": 99.5,
    "devex.time_to_first_device": 180,
}


# =============================================================================
# Timestream Integration
# =============================================================================

def get_timestream_client():
    if TIMESTREAM_DATABASE:
        return boto3.client('timestream-query', region_name=AWS_REGION)
    return None


async def query_device_metrics(device_id: str, metric: str, hours: int = 24) -> list:
    client = get_timestream_client()
    if not client:
        return [
            {"time": (datetime.utcnow() - timedelta(hours=i)).isoformat(), "value": 75 + (i % 10)}
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
    await init_db()
    yield
    await engine.dispose()
    logger.info("Analytics Service shutting down...")


app = FastAPI(
    title="Analytics Service",
    description="Metrics, SLOs, and Developer Experience Analytics",
    version="2.0.0",
    lifespan=lifespan,
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
        "instance": socket.gethostname(),
        "timestream_configured": bool(TIMESTREAM_DATABASE),
        "slos_defined": len(slos_db),
        "metrics_tracked": len(current_metrics),
    }


# SLOs
@app.get("/api/v1/analytics/slos", tags=["SLOs"])
async def list_slos():
    return {"slos": list(slos_db.values())}


@app.get("/api/v1/analytics/slos/status", tags=["SLOs"])
async def get_slo_status():
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
            error_budget_remaining=min(100, error_budget),
        ))
    return {"slo_status": statuses}


@app.get("/api/v1/analytics/slos/{slo_id}", tags=["SLOs"])
async def get_slo(slo_id: str):
    if slo_id not in slos_db:
        raise HTTPException(status_code=404, detail="SLO not found")
    return slos_db[slo_id]


# DevEx
@app.get("/api/v1/analytics/devex", tags=["DevEx"])
async def get_devex_metrics():
    return {
        "metrics": {
            "time_to_first_device": {"value": 180, "unit": "seconds", "target": 300, "status": "healthy"},
            "api_docs_satisfaction": {"value": 4.2, "unit": "rating", "target": 4.0, "status": "healthy"},
            "deployment_frequency": {"value": 12, "unit": "deploys/week", "target": 10, "status": "healthy"},
            "mean_time_to_recovery": {"value": 15, "unit": "minutes", "target": 30, "status": "healthy"},
            "golden_path_adoption": {"value": 85, "unit": "percent", "target": 80, "status": "healthy"},
        }
    }


@app.post("/api/v1/analytics/devex/track", tags=["DevEx"])
async def track_devex_event(
    metric_name: str,
    value: float,
    category: str = "general",
    session: AsyncSession = Depends(get_session),
):
    metric = DevExMetric(
        id=f"metric-{uuid.uuid4().hex[:10]}",
        name=metric_name,
        category=category,
        value=value,
        unit="custom",
    )
    session.add(metric)
    await session.commit()
    await session.refresh(metric)
    return {"tracked": metric}


@app.get("/api/v1/analytics/devex/recent", tags=["DevEx"])
async def get_recent_devex_metrics(
    limit: int = Query(50, ge=1, le=500),
    category: Optional[str] = None,
    session: AsyncSession = Depends(get_session),
):
    stmt = select(DevExMetric).order_by(desc(DevExMetric.measured_at)).limit(limit)
    if category:
        stmt = stmt.where(DevExMetric.category == category)
    metrics = (await session.execute(stmt)).scalars().all()
    return {"metrics": metrics}


# Maturity (static)
@app.get("/api/v1/analytics/maturity", tags=["Maturity"])
async def get_maturity_assessment():
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
                    "Container orchestration (ECS Fargate)",
                ],
                recommendations=["Add multi-region deployment", "Implement chaos engineering"],
            ),
            PlatformMaturityAssessment(
                dimension="Developer Experience",
                level=2,
                score=2.5,
                evidence=[
                    "Self-service API for device registration",
                    "API documentation available",
                    "Golden Path templates for automations",
                ],
                recommendations=[
                    "Add interactive API explorer",
                    "Implement developer portal",
                    "Add more Golden Path templates",
                ],
            ),
            PlatformMaturityAssessment(
                dimension="Observability",
                level=2,
                score=2.0,
                evidence=[
                    "Centralized logging (CloudWatch)",
                    "Basic SLO tracking",
                    "Time-series metrics (Timestream)",
                ],
                recommendations=[
                    "Add distributed tracing",
                    "Implement SLO dashboards",
                    "Add alerting automation",
                ],
            ),
            PlatformMaturityAssessment(
                dimension="Security",
                level=2,
                score=2.5,
                evidence=[
                    "API key authentication",
                    "Secrets management (Secrets Manager)",
                    "Security scanning in CI/CD",
                ],
                recommendations=["Add OAuth2/OIDC support", "Implement RBAC", "Add audit logging"],
            ),
        ],
    }


# Device analytics (Timestream)
@app.get("/api/v1/analytics/devices/{device_id}/metrics", tags=["Device Analytics"])
async def get_device_metrics(
    device_id: str,
    metric: str = Query("brightness", description="Metric to query"),
    hours: int = Query(24, ge=1, le=168),
):
    data = await query_device_metrics(device_id, metric, hours)
    return {
        "device_id": device_id,
        "metric": metric,
        "period_hours": hours,
        "data": data,
    }


@app.get("/api/v1/analytics/devices/summary", tags=["Device Analytics"])
async def get_devices_summary():
    return {
        "total_devices": 5,
        "online_devices": 4,
        "offline_devices": 1,
        "commands_today": 127,
        "automations_triggered": 23,
        "avg_response_time_ms": 245,
    }


@app.get("/api/v1/analytics/usage", tags=["Usage"])
async def get_usage_stats():
    return {
        "api_calls_24h": 1523,
        "unique_users_24h": 12,
        "devices_registered_7d": 8,
        "automations_created_7d": 5,
        "top_endpoints": [
            {"endpoint": "/api/v1/device/devices", "calls": 450},
            {"endpoint": "/api/v1/device/devices/{id}/state", "calls": 320},
            {"endpoint": "/api/v1/automation/rules", "calls": 180},
        ],
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8004)
