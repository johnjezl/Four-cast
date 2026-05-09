"""
Automation Service
==================
Manages automation rules and Golden Path templates.

Storage: Postgres for rules and execution logs. Templates are immutable seed data
kept in-memory.
"""

import os
import uuid
import socket
import logging
from datetime import datetime
from typing import Optional
from contextlib import asynccontextmanager
from enum import Enum

from fastapi import FastAPI, HTTPException, BackgroundTasks, Depends
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field as PydanticField
from sqlalchemy import Column, desc, text
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import Field, SQLModel, select

from .db import async_session, engine, get_session, init_db

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

DEVICE_EVENTS_QUEUE = os.getenv("DEVICE_EVENTS_QUEUE", "")
IOT_ENDPOINT = os.getenv("IOT_ENDPOINT", "")
AWS_REGION = os.getenv("AWS_REGION", "us-east-1")


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
    logger.info("Automation Service starting...")
    await init_db()
    yield
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


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8002)
