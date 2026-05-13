"""
Automation Service
==================
Manages automation rules and Golden Path templates.

Storage: Postgres for rules and execution logs. Templates are immutable seed data
kept in-memory.
"""

import asyncio
import os
import time
import uuid
import socket
import logging
from datetime import datetime
from typing import Optional
from contextlib import asynccontextmanager
from enum import Enum

import httpx
from fastapi import FastAPI, HTTPException, BackgroundTasks, Depends
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field as PydanticField
from sqlalchemy import Column, desc, text
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import Field, SQLModel, select

from .db import async_session, engine, get_session, init_db

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO").upper())
logger = logging.getLogger(__name__)

DEVICE_SERVICE_URL = os.environ.get("DEVICE_SERVICE_URL", "").rstrip("/")
INTERNAL_TOKEN = os.environ.get("INTERNAL_TOKEN", "")
http_client: Optional[httpx.AsyncClient] = None


# =============================================================================
# Models
# =============================================================================

class TriggerType(str, Enum):
    DEVICE_STATE = "device_state"
    SCHEDULE = "schedule"
    MANUAL = "manual"


class AutomationTemplate(BaseModel):
    """Golden Path template (in-memory seed)."""
    id: str
    name: str
    description: str
    category: str
    trigger_type: TriggerType
    trigger_config: dict
    actions: list[dict]
    enabled: bool = True


class AutomationRule(SQLModel, table=True):
    __tablename__ = "automation_rules"
    id: str = Field(primary_key=True)
    name: str
    description: Optional[str] = None
    template_id: Optional[str] = None
    trigger_type: str
    trigger_config: dict = Field(default_factory=dict, sa_column=Column(JSONB, nullable=False, server_default=text("'{}'::jsonb")))
    actions: list = Field(default_factory=list, sa_column=Column(JSONB, nullable=False, server_default=text("'[]'::jsonb")))
    enabled: bool = True
    created_at: datetime = Field(default_factory=datetime.utcnow)
    last_triggered: Optional[datetime] = None
    trigger_count: int = 0


class RuleCreate(BaseModel):
    name: str
    description: Optional[str] = None
    template_id: Optional[str] = None
    trigger_type: TriggerType
    trigger_config: dict
    actions: list[dict]


class ExecutionLog(SQLModel, table=True):
    __tablename__ = "automation_execution_logs"
    id: str = Field(primary_key=True)
    rule_id: str = Field(index=True)
    triggered_at: datetime = Field(default_factory=datetime.utcnow, index=True)
    trigger_event: dict = Field(default_factory=dict, sa_column=Column(JSONB, nullable=False, server_default=text("'{}'::jsonb")))
    actions_executed: list = Field(default_factory=list, sa_column=Column(JSONB, nullable=False, server_default=text("'[]'::jsonb")))
    success: bool = True
    error: Optional[str] = None


# =============================================================================
# Seeded Templates (Golden Paths)
# =============================================================================

templates_db: dict[str, AutomationTemplate] = {
    "sunset-lights": AutomationTemplate(
        id="sunset-lights",
        name="Sunset Lights On",
        description="Turn on lights automatically at sunset",
        category="lighting",
        trigger_type=TriggerType.SCHEDULE,
        trigger_config={"time": "sunset", "offset_minutes": -15},
        actions=[{"type": "set_state", "target": "all_lights", "state": {"switch_led": True, "bright_value_v2": 800}}],
    ),
    "motion-lights": AutomationTemplate(
        id="motion-lights",
        name="Motion-Activated Lights",
        description="Turn on lights when motion is detected",
        category="lighting",
        trigger_type=TriggerType.DEVICE_STATE,
        trigger_config={"device_type": "motion_sensor", "state": {"motion": True}},
        actions=[{"type": "set_state", "target": "room_lights", "state": {"switch_led": True}}],
    ),
    "away-mode": AutomationTemplate(
        id="away-mode",
        name="Away Mode",
        description="Turn off all devices when leaving home",
        category="security",
        trigger_type=TriggerType.MANUAL,
        trigger_config={},
        actions=[{"type": "set_state", "target": "all_devices", "state": {"switch_led": False}}],
    ),
    "energy-saver": AutomationTemplate(
        id="energy-saver",
        name="Energy Saver",
        description="Reduce brightness during peak hours",
        category="energy",
        trigger_type=TriggerType.SCHEDULE,
        trigger_config={"start_time": "14:00", "end_time": "19:00"},
        actions=[{"type": "set_state", "target": "all_lights", "state": {"bright_value_v2": 400}}],
    ),
}


# =============================================================================
# Rule Execution
# =============================================================================

async def execute_rule(rule_id: str, trigger_event: dict) -> None:
    async with async_session() as session:
        rule = await session.get(AutomationRule, rule_id)
        if not rule:
            return

        executed_actions = []
        success = True
        error = None

        try:
            for action in rule.actions:
                action_type = action.get("type")
                if action_type == "set_state":
                    executed_actions.append({
                        "type": action_type,
                        "target": action.get("target"),
                        "state": action.get("state", {}),
                        "success": True,
                    })
                elif action_type == "notify":
                    executed_actions.append({
                        "type": action_type,
                        "message": action.get("message", "Automation triggered"),
                        "success": True,
                    })

            rule.last_triggered = datetime.utcnow()
            rule.trigger_count += 1
            session.add(rule)

        except Exception as e:
            success = False
            error = str(e)
            logger.error(f"Error executing rule {rule_id}: {e}")

        log = ExecutionLog(
            id=f"exec-{uuid.uuid4().hex[:10]}",
            rule_id=rule_id,
            trigger_event=trigger_event,
            actions_executed=executed_actions,
            success=success,
            error=error,
        )
        session.add(log)
        await session.commit()


# =============================================================================
# Application
# =============================================================================

@asynccontextmanager
async def lifespan(app: FastAPI):
    global http_client
    logger.info("Automation Service starting...")
    await init_db()
    http_client = httpx.AsyncClient(timeout=5.0)
    yield
    await http_client.aclose()
    await engine.dispose()
    logger.info("Automation Service shutting down...")


app = FastAPI(
    title="Automation Service",
    description="Manages automation rules and Golden Path templates",
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
    return {"status": "healthy", "service": "automation-service"}


@app.get("/api/v1/automation/info")
async def info(session: AsyncSession = Depends(get_session)):
    rules = (await session.execute(select(AutomationRule))).scalars().all()
    return {
        "service": "automation-service",
        "instance": socket.gethostname(),
        "templates": len(templates_db),
        "rules": len(rules),
        "active_rules": len([r for r in rules if r.enabled]),
    }


# Templates (Golden Paths)
@app.get("/api/v1/automation/templates", tags=["Templates"])
async def list_templates(category: Optional[str] = None):
    templates = list(templates_db.values())
    if category:
        templates = [t for t in templates if t.category == category]
    return {"templates": templates}


@app.get("/api/v1/automation/templates/{template_id}", tags=["Templates"])
async def get_template(template_id: str):
    if template_id not in templates_db:
        raise HTTPException(status_code=404, detail="Template not found")
    return templates_db[template_id]


@app.post("/api/v1/automation/templates/{template_id}/apply", tags=["Templates"])
async def apply_template(
    template_id: str,
    name: Optional[str] = None,
    session: AsyncSession = Depends(get_session),
):
    if template_id not in templates_db:
        raise HTTPException(status_code=404, detail="Template not found")

    template = templates_db[template_id]
    rule_id = f"rule-{uuid.uuid4().hex[:8]}"

    rule = AutomationRule(
        id=rule_id,
        name=name or f"{template.name} (copy)",
        description=template.description,
        template_id=template_id,
        trigger_type=template.trigger_type.value,
        trigger_config=dict(template.trigger_config),
        actions=list(template.actions),
    )
    session.add(rule)
    await session.commit()
    await session.refresh(rule)
    return rule


# Rules CRUD
@app.get("/api/v1/automation/rules", tags=["Rules"])
async def list_rules(
    enabled: Optional[bool] = None,
    session: AsyncSession = Depends(get_session),
):
    stmt = select(AutomationRule)
    if enabled is not None:
        stmt = stmt.where(AutomationRule.enabled == enabled)
    rules = (await session.execute(stmt)).scalars().all()
    return {"rules": rules}


@app.post("/api/v1/automation/rules", tags=["Rules"], status_code=201)
async def create_rule(
    rule_create: RuleCreate,
    session: AsyncSession = Depends(get_session),
):
    rule_id = f"rule-{uuid.uuid4().hex[:8]}"
    rule = AutomationRule(
        id=rule_id,
        name=rule_create.name,
        description=rule_create.description,
        template_id=rule_create.template_id,
        trigger_type=rule_create.trigger_type.value,
        trigger_config=rule_create.trigger_config,
        actions=rule_create.actions,
    )
    session.add(rule)
    await session.commit()
    await session.refresh(rule)
    return rule


@app.get("/api/v1/automation/rules/{rule_id}", tags=["Rules"])
async def get_rule(rule_id: str, session: AsyncSession = Depends(get_session)):
    rule = await session.get(AutomationRule, rule_id)
    if not rule:
        raise HTTPException(status_code=404, detail="Rule not found")
    return rule


@app.delete("/api/v1/automation/rules/{rule_id}", tags=["Rules"])
async def delete_rule(rule_id: str, session: AsyncSession = Depends(get_session)):
    rule = await session.get(AutomationRule, rule_id)
    if not rule:
        raise HTTPException(status_code=404, detail="Rule not found")
    await session.delete(rule)
    await session.commit()
    return {"message": f"Rule {rule_id} deleted"}


@app.post("/api/v1/automation/rules/{rule_id}/enable", tags=["Rules"])
async def enable_rule(rule_id: str, session: AsyncSession = Depends(get_session)):
    rule = await session.get(AutomationRule, rule_id)
    if not rule:
        raise HTTPException(status_code=404, detail="Rule not found")
    rule.enabled = True
    session.add(rule)
    await session.commit()
    return {"message": "Rule enabled"}


@app.post("/api/v1/automation/rules/{rule_id}/disable", tags=["Rules"])
async def disable_rule(rule_id: str, session: AsyncSession = Depends(get_session)):
    rule = await session.get(AutomationRule, rule_id)
    if not rule:
        raise HTTPException(status_code=404, detail="Rule not found")
    rule.enabled = False
    session.add(rule)
    await session.commit()
    return {"message": "Rule disabled"}


@app.post("/api/v1/automation/rules/{rule_id}/trigger", tags=["Rules"])
async def trigger_rule_manually(
    rule_id: str,
    background_tasks: BackgroundTasks,
    session: AsyncSession = Depends(get_session),
):
    rule = await session.get(AutomationRule, rule_id)
    if not rule:
        raise HTTPException(status_code=404, detail="Rule not found")
    background_tasks.add_task(
        execute_rule,
        rule_id,
        {"type": "manual_trigger", "triggered_by": "api"},
    )
    return {"message": "Rule triggered"}


# Execution History
@app.get("/api/v1/automation/history", tags=["History"])
async def get_execution_history(
    limit: int = 20,
    session: AsyncSession = Depends(get_session),
):
    stmt = select(ExecutionLog).order_by(desc(ExecutionLog.triggered_at)).limit(limit)
    logs = (await session.execute(stmt)).scalars().all()
    return {"executions": logs}


# =============================================================================
# Demo: chase animation
# =============================================================================
# Demo endpoint that animates a brightness "rotating spotlight" across N
# bulbs by calling device-service's /brightness endpoint in a step loop.
# Bypasses the rule infrastructure because the rule executor (see
# trigger_rule_manually below) is currently a no-op — wiring rule
# actions to actually dispatch commands is a larger separate concern.
# Latency note: device-service forwards each call synchronously to
# tuya-bridge, so each step lands in ~500ms. The 60s tuya-bridge poll
# loop is irrelevant here — it's a separate reconciliation path.

# Cap total chase duration well under Cloud Run's 300s request
# timeout so the request can't be killed mid-animation, leaving
# bulbs in whatever frame they last received.
MAX_CHASE_DURATION_MS = 270_000


class ChaseRequest(BaseModel):
    device_ids: list[str]
    cycles: int = PydanticField(default=3, ge=1, le=20)
    step_ms: int = PydanticField(default=500, ge=100, le=5000)
    min_brightness: int = PydanticField(default=10, ge=0, le=100)
    max_brightness: int = PydanticField(default=100, ge=0, le=100)


async def _device_post(device_id: str, path_suffix: str, params: Optional[dict] = None) -> Optional[str]:
    """Generic POST to a device-service endpoint. Returns None on success
    or an error string on failure."""
    if not DEVICE_SERVICE_URL or http_client is None:
        return "DEVICE_SERVICE_URL not configured"
    try:
        r = await http_client.post(
            f"{DEVICE_SERVICE_URL}/api/v1/device/devices/{device_id}/{path_suffix}",
            params=params,
            headers={"X-Internal-Token": INTERNAL_TOKEN} if INTERNAL_TOKEN else {},
        )
        if r.status_code >= 400:
            return f"{device_id}: HTTP {r.status_code} {r.text[:120]}"
        return None
    except Exception as e:
        return f"{device_id}: {type(e).__name__}: {e}"


async def _set_power(device_id: str, on: bool) -> Optional[str]:
    return await _device_post(device_id, "on" if on else "off")


async def _set_brightness(device_id: str, level: int) -> Optional[str]:
    return await _device_post(device_id, "brightness", params={"level": level})


@app.post("/api/v1/automation/chase", tags=["Demo"])
async def run_chase(req: ChaseRequest):
    """Animate a rotating-spotlight chase across N bulbs.

    Ensures bulbs are on, normalizes them to `min_brightness`, then
    rotates the spotlight one slot per step for `cycles` full
    revolutions. Errors per command are collected and returned; a
    single failing bulb does not abort the chase.
    """
    if not DEVICE_SERVICE_URL or http_client is None:
        raise HTTPException(
            status_code=503,
            detail="DEVICE_SERVICE_URL not configured; chase cannot dispatch commands",
        )
    if not req.device_ids:
        raise HTTPException(status_code=400, detail="device_ids must be non-empty")
    if req.max_brightness <= req.min_brightness:
        raise HTTPException(
            status_code=400,
            detail="max_brightness must be greater than min_brightness",
        )

    n = len(req.device_ids)
    # Projection covers every step_ms sleep the handler will actually
    # do: `cycles * n` rotation-frame sleeps plus the one settling sleep
    # after the pre-zero frame. HTTP round-trip time during prefire and
    # per frame is variable and ignored here; the 30s cushion between
    # this cap and Cloud Run's 300s request timeout absorbs it.
    projected_ms = (req.cycles * n + 1) * req.step_ms
    if projected_ms > MAX_CHASE_DURATION_MS:
        raise HTTPException(
            status_code=400,
            detail=(
                f"chase would run for {projected_ms}ms, exceeding the "
                f"{MAX_CHASE_DURATION_MS}ms cap. Lower cycles, step_ms, "
                f"or device_ids."
            ),
        )

    started = time.monotonic()
    steps = 0
    errors: list[str] = []

    async def _gather(coros, label: Optional[str] = None) -> None:
        for result in await asyncio.gather(*coros):
            if result is not None:
                errors.append(f"{label}: {result}" if label else result)

    # Normalize starting state so frame 1 is a clean snap regardless of
    # what brightness the bulbs were at: first ensure power, then bring
    # everyone down to min_brightness. Errors from each phase are
    # labeled so callers can distinguish setup failures from rotation
    # failures.
    await _gather([_set_power(d, True) for d in req.device_ids], label="prefire-on")
    await _gather(
        [_set_brightness(d, req.min_brightness) for d in req.device_ids],
        label="prezero",
    )
    await asyncio.sleep(req.step_ms / 1000)

    # Rotating spotlight: at each step, one bulb is at max, the rest at
    # min. Position advances one slot per step. Commands within a step
    # are issued in parallel so the visible "snap" between frames is
    # close to simultaneous.
    for _ in range(req.cycles):
        for position in range(n):
            await _gather(
                [
                    _set_brightness(
                        device_id,
                        req.max_brightness if i == position else req.min_brightness,
                    )
                    for i, device_id in enumerate(req.device_ids)
                ]
            )
            steps += 1
            await asyncio.sleep(req.step_ms / 1000)

    return {
        "status": "completed",
        "steps_executed": steps,
        "duration_ms": int((time.monotonic() - started) * 1000),
        "errors": errors,
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8002)
