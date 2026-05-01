"""
Automation Service
==================
Manages automation rules and templates (Golden Paths).

Textbook Reference:
- Ch. 3: Golden Paths - Pre-built automation templates
- Ch. 3: Event-driven architecture via SQS

AWS Services Used:
- SQS: Receives device events, triggers automations
- IoT Core: Sends commands to devices via shadows
"""

import os
import json
import logging
from datetime import datetime, time
from typing import Optional
from contextlib import asynccontextmanager
from enum import Enum

from fastapi import FastAPI, HTTPException, BackgroundTasks
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
import boto3
from botocore.exceptions import ClientError

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Configuration
DEVICE_EVENTS_QUEUE = os.getenv("DEVICE_EVENTS_QUEUE", "")
IOT_ENDPOINT = os.getenv("IOT_ENDPOINT", "")
AWS_REGION = os.getenv("AWS_REGION", "us-east-1")


# =============================================================================
# Data Models
# =============================================================================

class TriggerType(str, Enum):
    DEVICE_STATE = "device_state"
    SCHEDULE = "schedule"
    MANUAL = "manual"


class ActionType(str, Enum):
    SET_STATE = "set_state"
    SEND_COMMAND = "send_command"
    NOTIFY = "notify"


class AutomationTemplate(BaseModel):
    """
    Pre-built automation template (Golden Path).
    
    Textbook Reference: Ch. 3 - Golden Paths reduce cognitive load
    by providing pre-configured solutions for common use cases.
    """
    id: str
    name: str
    description: str
    category: str
    trigger_type: TriggerType
    trigger_config: dict
    actions: list[dict]
    enabled: bool = True


class AutomationRule(BaseModel):
    """User-created automation rule (possibly from template)."""
    id: str
    name: str
    description: Optional[str] = None
    template_id: Optional[str] = None
    trigger_type: TriggerType
    trigger_config: dict
    actions: list[dict]
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


class ExecutionLog(BaseModel):
    id: str
    rule_id: str
    triggered_at: datetime
    trigger_event: dict
    actions_executed: list[dict]
    success: bool
    error: Optional[str] = None


# =============================================================================
# In-Memory Storage
# =============================================================================

# Golden Path Templates
templates_db: dict[str, AutomationTemplate] = {
    "sunset-lights": AutomationTemplate(
        id="sunset-lights",
        name="Sunset Lights On",
        description="Turn on lights automatically at sunset",
        category="lighting",
        trigger_type=TriggerType.SCHEDULE,
        trigger_config={"time": "sunset", "offset_minutes": -15},
        actions=[
            {"type": "set_state", "target": "all_lights", "state": {"switch_led": True, "bright_value_v2": 800}}
        ]
    ),
    "motion-lights": AutomationTemplate(
        id="motion-lights",
        name="Motion-Activated Lights",
        description="Turn on lights when motion is detected",
        category="lighting",
        trigger_type=TriggerType.DEVICE_STATE,
        trigger_config={"device_type": "motion_sensor", "state": {"motion": True}},
        actions=[
            {"type": "set_state", "target": "room_lights", "state": {"switch_led": True}}
        ]
    ),
    "away-mode": AutomationTemplate(
        id="away-mode",
        name="Away Mode",
        description="Turn off all devices when leaving home",
        category="security",
        trigger_type=TriggerType.MANUAL,
        trigger_config={},
        actions=[
            {"type": "set_state", "target": "all_devices", "state": {"switch_led": False}}
        ]
    ),
    "energy-saver": AutomationTemplate(
        id="energy-saver",
        name="Energy Saver",
        description="Reduce brightness during peak hours",
        category="energy",
        trigger_type=TriggerType.SCHEDULE,
        trigger_config={"start_time": "14:00", "end_time": "19:00"},
        actions=[
            {"type": "set_state", "target": "all_lights", "state": {"bright_value_v2": 400}}
        ]
    )
}

rules_db: dict[str, AutomationRule] = {}
execution_logs: list[ExecutionLog] = []


# =============================================================================
# SQS Event Processing
# =============================================================================

async def process_device_event(event: dict):
    """
    Process incoming device events and trigger matching automations.
    
    This is called when we receive events from SQS.
    """
    event_type = event.get("event_type")
    device_id = event.get("device_id")
    data = event.get("data", {})
    
    logger.info(f"Processing event: {event_type} from {device_id}")
    
    # Find matching rules
    for rule in rules_db.values():
        if not rule.enabled:
            continue
        
        if rule.trigger_type != TriggerType.DEVICE_STATE:
            continue
        
        # Check if trigger matches
        trigger_device = rule.trigger_config.get("device_id")
        trigger_state = rule.trigger_config.get("state", {})
        
        if trigger_device and trigger_device != device_id:
            continue
        
        # Check state conditions
        matches = all(
            data.get(k) == v for k, v in trigger_state.items()
        )
        
        if matches:
            await execute_rule(rule, event)


async def execute_rule(rule: AutomationRule, trigger_event: dict):
    """Execute automation rule actions."""
    logger.info(f"Executing rule: {rule.name}")
    
    executed_actions = []
    success = True
    error = None
    
    try:
        for action in rule.actions:
            action_type = action.get("type")
            target = action.get("target")
            state = action.get("state", {})
            
            if action_type == "set_state":
                # In production, this would call Device Service or IoT Core
                logger.info(f"Setting state on {target}: {state}")
                executed_actions.append({
                    "type": action_type,
                    "target": target,
                    "state": state,
                    "success": True
                })
            
            elif action_type == "notify":
                message = action.get("message", "Automation triggered")
                logger.info(f"Notification: {message}")
                executed_actions.append({
                    "type": action_type,
                    "message": message,
                    "success": True
                })
        
        # Update rule stats
        rule.last_triggered = datetime.utcnow()
        rule.trigger_count += 1
        
    except Exception as e:
        success = False
        error = str(e)
        logger.error(f"Error executing rule {rule.id}: {e}")
    
    # Log execution
    log = ExecutionLog(
        id=f"exec-{len(execution_logs) + 1:06d}",
        rule_id=rule.id,
        triggered_at=datetime.utcnow(),
        trigger_event=trigger_event,
        actions_executed=executed_actions,
        success=success,
        error=error
    )
    execution_logs.append(log)
    
    # Keep only last 100 logs
    if len(execution_logs) > 100:
        execution_logs.pop(0)


# =============================================================================
# Application
# =============================================================================

@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Automation Service starting...")
    yield
    logger.info("Automation Service shutting down...")


app = FastAPI(
    title="Automation Service",
    description="Manages automation rules and Golden Path templates",
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
    return {"status": "healthy", "service": "automation-service"}


@app.get("/api/v1/automation/info")
async def info():
    return {
        "service": "automation-service",
        "templates": len(templates_db),
        "rules": len(rules_db),
        "active_rules": len([r for r in rules_db.values() if r.enabled])
    }


# Templates (Golden Paths)
@app.get("/api/v1/automation/templates", tags=["Templates"])
async def list_templates(category: Optional[str] = None):
    """
    List available automation templates.
    
    Textbook Reference: Ch. 3 - Golden Paths
    """
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
async def apply_template(template_id: str, name: Optional[str] = None):
    """Create a new rule from a template."""
    if template_id not in templates_db:
        raise HTTPException(status_code=404, detail="Template not found")
    
    template = templates_db[template_id]
    rule_id = f"rule-{len(rules_db) + 1:04d}"
    
    rule = AutomationRule(
        id=rule_id,
        name=name or f"{template.name} (copy)",
        description=template.description,
        template_id=template_id,
        trigger_type=template.trigger_type,
        trigger_config=template.trigger_config.copy(),
        actions=template.actions.copy()
    )
    
    rules_db[rule_id] = rule
    return rule


# Rules CRUD
@app.get("/api/v1/automation/rules", tags=["Rules"])
async def list_rules(enabled: Optional[bool] = None):
    rules = list(rules_db.values())
    if enabled is not None:
        rules = [r for r in rules if r.enabled == enabled]
    return {"rules": rules}


@app.post("/api/v1/automation/rules", tags=["Rules"], status_code=201)
async def create_rule(rule_create: RuleCreate):
    rule_id = f"rule-{len(rules_db) + 1:04d}"
    rule = AutomationRule(id=rule_id, **rule_create.model_dump())
    rules_db[rule_id] = rule
    return rule


@app.get("/api/v1/automation/rules/{rule_id}", tags=["Rules"])
async def get_rule(rule_id: str):
    if rule_id not in rules_db:
        raise HTTPException(status_code=404, detail="Rule not found")
    return rules_db[rule_id]


@app.delete("/api/v1/automation/rules/{rule_id}", tags=["Rules"])
async def delete_rule(rule_id: str):
    if rule_id not in rules_db:
        raise HTTPException(status_code=404, detail="Rule not found")
    rules_db.pop(rule_id)
    return {"message": f"Rule {rule_id} deleted"}


@app.post("/api/v1/automation/rules/{rule_id}/enable", tags=["Rules"])
async def enable_rule(rule_id: str):
    if rule_id not in rules_db:
        raise HTTPException(status_code=404, detail="Rule not found")
    rules_db[rule_id].enabled = True
    return {"message": "Rule enabled"}


@app.post("/api/v1/automation/rules/{rule_id}/disable", tags=["Rules"])
async def disable_rule(rule_id: str):
    if rule_id not in rules_db:
        raise HTTPException(status_code=404, detail="Rule not found")
    rules_db[rule_id].enabled = False
    return {"message": "Rule disabled"}


@app.post("/api/v1/automation/rules/{rule_id}/trigger", tags=["Rules"])
async def trigger_rule_manually(rule_id: str, background_tasks: BackgroundTasks):
    """Manually trigger a rule."""
    if rule_id not in rules_db:
        raise HTTPException(status_code=404, detail="Rule not found")
    
    rule = rules_db[rule_id]
    background_tasks.add_task(
        execute_rule, 
        rule, 
        {"type": "manual_trigger", "triggered_by": "api"}
    )
    return {"message": "Rule triggered"}


# Execution History
@app.get("/api/v1/automation/history", tags=["History"])
async def get_execution_history(limit: int = 20):
    return {"executions": execution_logs[-limit:]}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8002)
