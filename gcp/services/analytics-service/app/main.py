"""
Analytics Service
=================
Consumes device events from SQS, persists them to Postgres (event_log),
and surfaces aggregates as platform metrics + SLO status.

Static seed data:
- SLO definitions
- Platform maturity assessment

Dynamic data:
- event_log table, populated by the background SQS consumer
- /devices/summary derives counts from event_log + a live call to device-service
- /usage and /devices/{id}/metrics derive directly from event_log
"""

import asyncio
import json
import logging
import os
import socket
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timedelta
from typing import Optional

import boto3
import httpx
from botocore.exceptions import ClientError
from fastapi import Depends, FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from sqlalchemy import Column, desc, func, text
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import Field, SQLModel, select

from .db import async_session, engine, get_session, init_db

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO").upper())
logger = logging.getLogger(__name__)

# =============================================================================
# Configuration
# =============================================================================

DEVICE_EVENTS_QUEUE = os.getenv("DEVICE_EVENTS_QUEUE", "")
DEVICE_SERVICE_URL = os.getenv("DEVICE_SERVICE_URL", "").rstrip("/")
AWS_REGION = os.getenv("AWS_REGION", "us-east-1")

# Rolling window used by /devex for the "measured" average. Older
# samples are intentionally excluded so a year-old reading doesn't
# weight today's number.
DEVEX_WINDOW = timedelta(days=30)

sqs_client = None
http_client: Optional[httpx.AsyncClient] = None


def get_sqs_client():
    global sqs_client
    if sqs_client is None:
        sqs_client = boto3.client("sqs", region_name=AWS_REGION)
    return sqs_client


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


class EventLog(SQLModel, table=True):
    """Persisted form of every device event we receive from SQS."""
    __tablename__ = "event_log"
    id: str = Field(primary_key=True)
    event_type: str = Field(index=True)
    device_id: Optional[str] = Field(default=None, index=True)
    device_name: Optional[str] = None
    data: dict = Field(
        default_factory=dict,
        sa_column=Column(JSONB, nullable=False, server_default=text("'{}'::jsonb")),
    )
    # Producer-side wall-clock from the message body (best-effort).
    source_timestamp: Optional[datetime] = None
    # When the consumer wrote it to Postgres — this is what we filter on.
    received_at: datetime = Field(default_factory=datetime.utcnow, index=True)


class PlatformMaturityAssessment(BaseModel):
    dimension: str
    level: int
    score: float
    evidence: list[str]
    recommendations: list[str]


# =============================================================================
# Static / Seed Data
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

# Static placeholders. Real latency/availability measurement isn't wired
# up — we don't have request-level metrics or synthetic probes yet, so
# these are not derived from event_log. Treat as demo values; see the
# `mock` flag on /slos/status responses.
SLO_CURRENT_METRICS = {
    "device.registration.latency_p95": 850,
    "api.availability": 99.8,
    "device.sync.success_rate": 99.5,
    "devex.time_to_first_device": 180,
}


# =============================================================================
# SQS consumer
# =============================================================================

async def consume_events_once() -> int:
    """One poll cycle against the device_events queue. Returns the number
    of messages successfully written to event_log. Failures are logged
    and left on the queue — SQS visibility timeout + the redrive policy
    handle retries and dead-lettering.

    Per-message commits (not a batch commit) are deliberate: one poison
    message in a batch shouldn't roll back the other nine. Don't
    "optimize" by moving the commit outside the loop.

    Operator note: with desired_count > 1, multiple analytics replicas
    consume from the same queue. SQS distributes; the DLQ redrive
    threshold (maxReceiveCount=3) is per-message and counts across all
    replicas, so transient errors across instances can DLQ faster than
    expected.
    """
    client = get_sqs_client()
    if not client or not DEVICE_EVENTS_QUEUE:
        # Service can still serve read endpoints; just don't consume.
        await asyncio.sleep(10)
        return 0

    try:
        resp = await asyncio.to_thread(
            client.receive_message,
            QueueUrl=DEVICE_EVENTS_QUEUE,
            MaxNumberOfMessages=10,
            WaitTimeSeconds=10,
        )
    except ClientError as e:
        logger.error(f"SQS receive failed: {e}")
        await asyncio.sleep(5)
        return 0

    messages = resp.get("Messages", [])
    if not messages:
        return 0

    processed = 0
    async with async_session() as session:
        for msg in messages:
            try:
                body = json.loads(msg["Body"])
                source_ts: Optional[datetime] = None
                if "timestamp" in body:
                    try:
                        # TODO: device-service emits datetime.utcnow().isoformat().
                        # If another producer joins this queue with a different
                        # timestamp format, we'll silently drop source_timestamp.
                        source_ts = datetime.fromisoformat(body["timestamp"])
                    except ValueError:
                        pass

                # Use the SQS MessageId as the primary key. SQS guarantees
                # at-least-once delivery; if a redelivery slips past our
                # delete, ON CONFLICT DO NOTHING keeps the insert idempotent
                # rather than creating duplicate rows.
                stmt = pg_insert(EventLog).values(
                    id=msg["MessageId"],
                    event_type=body.get("event_type", "unknown"),
                    device_id=body.get("device_id"),
                    device_name=body.get("device_name"),
                    data=body.get("data") or {},
                    source_timestamp=source_ts,
                    received_at=datetime.utcnow(),
                ).on_conflict_do_nothing(index_elements=["id"])
                await session.execute(stmt)
                await session.commit()
            except Exception as e:
                logger.error(f"Failed to persist event: {e}")
                await session.rollback()
                # Don't delete from SQS — visibility timeout will resurface it.
                continue

            try:
                await asyncio.to_thread(
                    client.delete_message,
                    QueueUrl=DEVICE_EVENTS_QUEUE,
                    ReceiptHandle=msg["ReceiptHandle"],
                )
                processed += 1
            except ClientError as e:
                # Already persisted; the delete failure means the message
                # will resurface. The ON CONFLICT guard above makes the
                # retry insert a no-op, so no duplicate row.
                logger.warning(f"SQS delete failed (will re-receive): {e}")

    return processed


async def consume_events_forever():
    while True:
        try:
            count = await consume_events_once()
            if count:
                logger.debug(f"Consumed {count} event(s)")
        except asyncio.CancelledError:
            raise
        except Exception as e:
            logger.error(f"Event consumer crashed: {e}")
            await asyncio.sleep(5)


# =============================================================================
# Application
# =============================================================================


@asynccontextmanager
async def lifespan(app: FastAPI):
    global http_client
    http_client = httpx.AsyncClient()
    logger.info("Analytics Service starting...")
    await init_db()
    consumer_task = asyncio.create_task(consume_events_forever())
    if DEVICE_EVENTS_QUEUE:
        logger.info("Event consumer started; polling %s", DEVICE_EVENTS_QUEUE)
    else:
        logger.warning("DEVICE_EVENTS_QUEUE not configured; consumer will idle")
    try:
        yield
    finally:
        consumer_task.cancel()
        try:
            await consumer_task
        except (asyncio.CancelledError, Exception):
            pass
        await http_client.aclose()
        await engine.dispose()
        logger.info("Analytics Service shutting down...")


app = FastAPI(
    title="Analytics Service",
    description="Event-driven metrics, SLOs, and DevEx analytics",
    version="3.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# =============================================================================
# Health & Info
# =============================================================================

@app.get("/health")
async def health():
    return {"status": "healthy", "service": "analytics-service"}


@app.get("/api/v1/analytics/info")
async def info():
    return {
        "service": "analytics-service",
        "instance": socket.gethostname(),
        "version": "3.0.0",
        "integrations": {
            "device_events_queue": bool(DEVICE_EVENTS_QUEUE),
            "device_service": bool(DEVICE_SERVICE_URL),
        },
        "slos_defined": len(slos_db),
    }


# =============================================================================
# SLOs
# =============================================================================

@app.get("/api/v1/analytics/slos", tags=["SLOs"])
async def list_slos():
    return {"slos": list(slos_db.values())}


@app.get("/api/v1/analytics/slos/status", tags=["SLOs"])
async def get_slo_status():
    statuses = []
    for slo in slos_db.values():
        current = SLO_CURRENT_METRICS.get(slo.metric, 0)
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
    # `mock` indicates that current values come from static placeholders
    # rather than measured telemetry. Real latency/availability tracking
    # is a separate workstream.
    return {"slo_status": statuses, "mock": True}


@app.get("/api/v1/analytics/slos/{slo_id}", tags=["SLOs"])
async def get_slo(slo_id: str):
    if slo_id not in slos_db:
        raise HTTPException(status_code=404, detail="SLO not found")
    return slos_db[slo_id]


# =============================================================================
# DevEx (Postgres-backed track + recent; aggregate read is partly static)
# =============================================================================

@app.get("/api/v1/analytics/devex", tags=["DevEx"])
async def get_devex_metrics(session: AsyncSession = Depends(get_session)):
    """Headline DevEx metrics. Aggregates from devex_metrics within the
    last DEVEX_WINDOW; falls back to demo defaults for metrics we don't
    yet measure or that have no recent samples."""
    cutoff = datetime.utcnow() - DEVEX_WINDOW
    measured: dict[str, float] = {}
    rows = (await session.execute(
        select(DevExMetric.name, func.avg(DevExMetric.value))
        .where(DevExMetric.measured_at >= cutoff)
        .group_by(DevExMetric.name)
    )).all()
    for name, avg in rows:
        measured[name] = float(avg)

    def metric(name: str, default: float, unit: str, target: float, lower_is_better: bool = False):
        value = measured.get(name, default)
        ok = value <= target if lower_is_better else value >= target
        return {
            "value": value,
            "unit": unit,
            "target": target,
            "status": "healthy" if ok else "warning",
            "source": "measured" if name in measured else "default",
        }

    return {
        "metrics": {
            "time_to_first_device": metric("time_to_first_device", 180, "seconds", 300, lower_is_better=True),
            "api_docs_satisfaction": metric("api_docs_satisfaction", 4.2, "rating", 4.0),
            "deployment_frequency": metric("deployment_frequency", 12, "deploys/week", 10),
            "mean_time_to_recovery": metric("mean_time_to_recovery", 15, "minutes", 30, lower_is_better=True),
            "golden_path_adoption": metric("golden_path_adoption", 85, "percent", 80),
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


# =============================================================================
# Platform Maturity (static)
# =============================================================================

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
                    "Event log persisted to Postgres",
                    "Basic SLO tracking",
                ],
                recommendations=[
                    "Add distributed tracing",
                    "Wire real latency/availability into SLO status",
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
                    "Scoped IAM per service",
                ],
                recommendations=["Add OAuth2/OIDC support", "Implement RBAC", "Add audit logging"],
            ),
        ],
    }


# =============================================================================
# Device analytics (event-log backed)
# =============================================================================

@app.get("/api/v1/analytics/devices/summary", tags=["Device Analytics"])
async def get_devices_summary(session: AsyncSession = Depends(get_session)):
    total = online = offline = 0
    device_service_ok = False
    if DEVICE_SERVICE_URL and http_client is not None:
        try:
            r = await http_client.get(
                f"{DEVICE_SERVICE_URL}/api/v1/device/devices", timeout=5.0
            )
            r.raise_for_status()
            devices = r.json().get("devices", [])
            total = len(devices)
            online = sum(1 for d in devices if d.get("online"))
            offline = total - online
            device_service_ok = True
        except Exception as e:
            logger.warning(f"device-service unavailable for /summary: {e}")

    today_start = datetime.utcnow().replace(hour=0, minute=0, second=0, microsecond=0)
    commands_today = (await session.execute(
        select(func.count()).select_from(EventLog).where(
            EventLog.event_type.in_(["device.command", "device.state_changed"]),
            EventLog.received_at >= today_start,
        )
    )).scalar_one()
    automations_today = (await session.execute(
        select(func.count()).select_from(EventLog).where(
            EventLog.event_type.like("automation.%"),
            EventLog.received_at >= today_start,
        )
    )).scalar_one()

    return {
        "total_devices": total,
        "online_devices": online,
        "offline_devices": offline,
        "commands_today": commands_today,
        "automations_triggered": automations_today,
        "device_service_reachable": device_service_ok,
    }


@app.get("/api/v1/analytics/devices/{device_id}/metrics", tags=["Device Analytics"])
async def get_device_metrics(
    device_id: str,
    event_type: str = Query(
        "device.state_changed",
        description="Filter by event type (e.g. device.state_changed, device.command)",
    ),
    hours: int = Query(24, ge=1, le=168),
    session: AsyncSession = Depends(get_session),
):
    cutoff = datetime.utcnow() - timedelta(hours=hours)
    events = (await session.execute(
        select(EventLog)
        .where(
            EventLog.device_id == device_id,
            EventLog.event_type == event_type,
            EventLog.received_at >= cutoff,
        )
        .order_by(desc(EventLog.received_at))
        .limit(500)
    )).scalars().all()
    return {
        "device_id": device_id,
        "event_type": event_type,
        "period_hours": hours,
        "events": [
            {
                "received_at": e.received_at.isoformat(),
                "source_timestamp": e.source_timestamp.isoformat() if e.source_timestamp else None,
                "data": e.data,
            }
            for e in events
        ],
        "count": len(events),
    }


# =============================================================================
# Usage
# =============================================================================

@app.get("/api/v1/analytics/usage", tags=["Usage"])
async def get_usage_stats(session: AsyncSession = Depends(get_session)):
    day_ago = datetime.utcnow() - timedelta(days=1)
    week_ago = datetime.utcnow() - timedelta(days=7)

    events_24h = (await session.execute(
        select(func.count()).select_from(EventLog).where(EventLog.received_at >= day_ago)
    )).scalar_one()
    devices_registered_7d = (await session.execute(
        select(func.count()).select_from(EventLog).where(
            EventLog.event_type == "device.created",
            EventLog.received_at >= week_ago,
        )
    )).scalar_one()
    automations_created_7d = (await session.execute(
        select(func.count()).select_from(EventLog).where(
            EventLog.event_type == "automation.created",
            EventLog.received_at >= week_ago,
        )
    )).scalar_one()

    top_events_rows = (await session.execute(
        select(EventLog.event_type, func.count().label("count"))
        .where(EventLog.received_at >= day_ago)
        .group_by(EventLog.event_type)
        .order_by(desc("count"))
        .limit(5)
    )).all()

    return {
        "events_24h": events_24h,
        "devices_registered_7d": devices_registered_7d,
        "automations_created_7d": automations_created_7d,
        "top_events": [{"event_type": e, "count": c} for e, c in top_events_rows],
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8004)
