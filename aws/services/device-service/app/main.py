"""
Device Service
==============
Manages device registration and shadow state. Shadow is stored in Postgres
(`devices.state` JSONB) using a {desired, reported, version} envelope.

Commands flow asynchronously to the tuya-bridge service over HTTP.
Reported state flows back from tuya-bridge via an internal endpoint
guarded by X-Internal-Token.
"""

import asyncio
import json
import logging
import os
import socket
import time
import uuid
from contextlib import asynccontextmanager
from datetime import datetime
from typing import Any, Optional

import boto3
import httpx
from botocore.exceptions import ClientError
from fastapi import Depends, FastAPI, Header, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field as PydanticField
from sqlalchemy import Column, Integer, cast, text
from sqlalchemy import update as sa_update
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import Field, SQLModel, select

from .db import engine, get_session, init_db

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO").upper())
logger = logging.getLogger(__name__)

# =============================================================================
# Configuration
# =============================================================================

DEVICE_EVENTS_QUEUE = os.getenv("DEVICE_EVENTS_QUEUE", "")
TUYA_BRIDGE_URL = os.getenv("TUYA_BRIDGE_URL", "").rstrip("/")
INTERNAL_TOKEN = os.getenv("INTERNAL_TOKEN", "")
AWS_REGION = os.getenv("AWS_REGION", "us-east-1")

# Retry policy for stuck desired-state commands. The tuya-bridge polls
# /internal/pending each tick; this endpoint filters by these bounds so a
# permanently-failing command can't re-fire forever.
PENDING_MAX_RETRIES = int(os.getenv("PENDING_MAX_RETRIES", "5"))
PENDING_BACKOFF_SECONDS = int(os.getenv("PENDING_BACKOFF_SECONDS", "60"))

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

class DeviceType(BaseModel):
    """Template for a category of devices (in-memory seed data)."""
    id: str
    name: str
    manufacturer: str
    capabilities: list[str] = PydanticField(default_factory=list)
    default_state: dict = PydanticField(default_factory=dict)


class Device(SQLModel, table=True):
    __tablename__ = "devices"
    id: str = Field(primary_key=True)
    name: str
    device_type_id: str
    tuya_device_id: Optional[str] = Field(default=None, index=True)
    room: Optional[str] = Field(default=None, index=True)
    # Shadow envelope: {"desired": {...}, "reported": {...}, "version": int}
    state: dict = Field(
        default_factory=dict,
        sa_column=Column(JSONB, nullable=False, server_default=text("'{}'::jsonb")),
    )
    online: bool = False
    last_seen: Optional[datetime] = None
    created_at: datetime = Field(default_factory=datetime.utcnow)


class DeviceCreate(BaseModel):
    name: str
    device_type_id: str
    tuya_device_id: Optional[str] = None
    room: Optional[str] = None


class DeviceStateUpdate(BaseModel):
    state: dict


class CommandRequest(BaseModel):
    command: str
    value: Any


class ReportedStateUpdate(BaseModel):
    tuya_device_id: str
    reported: dict


# =============================================================================
# Seeded Device Type Templates
# =============================================================================

device_types_db: dict[str, DeviceType] = {
    "tuya-smart-bulb": DeviceType(
        id="tuya-smart-bulb",
        name="Tuya Smart Bulb",
        manufacturer="MAXvolador",
        capabilities=["switch", "brightness", "color", "color_temp"],
        default_state={
            "switch_led": False,
            "bright_value_v2": 500,
            "colour_data_v2": {"h": 0, "s": 0, "v": 1000},
            "work_mode": "white",
        },
    ),
    "tuya-smart-plug": DeviceType(
        id="tuya-smart-plug",
        name="Tuya Smart Plug",
        manufacturer="Generic",
        capabilities=["switch", "energy_monitoring"],
        default_state={"switch": False, "cur_power": 0, "cur_voltage": 0},
    ),
}


# =============================================================================
# Shadow helpers
# =============================================================================

def _empty_envelope() -> dict:
    return {
        "desired": {},
        "reported": {},
        "version": 0,
        "retry_count": 0,
        "last_attempted": None,
    }


def _envelope(state: Optional[dict]) -> dict:
    """Normalize any persisted state into the canonical envelope shape.
    Tolerates legacy flat-dict rows by treating them as reported state."""
    if not state:
        return _empty_envelope()
    if "desired" in state or "reported" in state:
        return {
            "desired": state.get("desired") or {},
            "reported": state.get("reported") or {},
            "version": state.get("version", 0),
            "retry_count": state.get("retry_count", 0),
            "last_attempted": state.get("last_attempted"),
        }
    # Legacy flat shape — promote to reported.
    return {
        "desired": {},
        "reported": dict(state),
        "version": 0,
        "retry_count": 0,
        "last_attempted": None,
    }


def _merged_view(env: dict) -> dict:
    """User-facing flattened state: reported with desired keys overlaid."""
    return {**env.get("reported", {}), **env.get("desired", {})}


async def _save_envelope(
    session: AsyncSession,
    device_id: str,
    mutate,
    max_retries: int = 3,
) -> tuple["Device", dict]:
    """Apply `mutate(env) -> new_env` to a device's shadow envelope with
    optimistic concurrency. Re-reads on version conflict; raises 409 after
    `max_retries` consecutive conflicts. Returns the (device, new_env)
    pair — callers should use the returned Device rather than re-fetching,
    since the bulk UPDATE bypasses the ORM identity map and a follow-up
    session.get() may return stale state."""
    for _ in range(max_retries):
        stmt = (
            select(Device)
            .where(Device.id == device_id)
            .execution_options(populate_existing=True)
        )
        device = (await session.execute(stmt)).scalar_one_or_none()
        if not device:
            raise HTTPException(status_code=404, detail="Device not found")

        env = _envelope(device.state)
        expected_version = env["version"]
        new_env = mutate(env)
        new_env["version"] = expected_version + 1

        result = await session.execute(
            sa_update(Device)
            .where(Device.id == device_id)
            .where(cast(Device.state["version"].astext, Integer) == expected_version)
            .values(state=new_env)
        )
        await session.commit()
        if result.rowcount == 1:
            return device, new_env
    raise HTTPException(status_code=409, detail="shadow modified concurrently, retry")


# =============================================================================
# tuya-bridge HTTP client
# =============================================================================

def _bridge_headers() -> dict:
    return {"X-Internal-Token": INTERNAL_TOKEN} if INTERNAL_TOKEN else {}


async def dispatch_command(tuya_device_id: str, desired: dict) -> None:
    """Fire-and-forget POST to tuya-bridge. The bridge owns retries and
    reporting back. We don't await — the API returns to the caller as
    soon as the desired write is durable in Postgres."""
    if not TUYA_BRIDGE_URL or not tuya_device_id or not desired:
        return

    async def _send():
        try:
            await http_client.post(
                f"{TUYA_BRIDGE_URL}/api/v1/tuya-bridge/command",
                json={"tuya_device_id": tuya_device_id, "desired": desired},
                headers=_bridge_headers(),
                timeout=10.0,
            )
        except Exception as e:
            logger.warning(f"dispatch_command failed for {tuya_device_id}: {e}")

    asyncio.create_task(_send())


# =============================================================================
# SQS event publishing
# =============================================================================

async def publish_device_event(event_type: str, device: Device, data: dict = None):
    client = get_sqs_client()
    if not client or not DEVICE_EVENTS_QUEUE:
        return
    message = {
        "event_type": event_type,
        "device_id": device.id,
        "device_name": device.name,
        "timestamp": datetime.utcnow().isoformat(),
        "data": data or {},
    }
    try:
        await asyncio.to_thread(
            client.send_message,
            QueueUrl=DEVICE_EVENTS_QUEUE,
            MessageBody=json.dumps(message),
            MessageAttributes={
                "event_type": {"DataType": "String", "StringValue": event_type}
            },
        )
    except ClientError as e:
        logger.error(f"Error publishing event: {e}")


# =============================================================================
# Internal token guard
# =============================================================================

def require_internal_token(x_internal_token: Optional[str] = Header(None)):
    if not INTERNAL_TOKEN:
        return  # unconfigured — allow (dev mode)
    if x_internal_token != INTERNAL_TOKEN:
        raise HTTPException(status_code=401, detail="invalid internal token")


# =============================================================================
# Application
# =============================================================================

@asynccontextmanager
async def lifespan(app: FastAPI):
    global http_client
    http_client = httpx.AsyncClient()
    logger.info("Device Service starting...")
    await init_db()
    try:
        yield
    finally:
        await http_client.aclose()
        await engine.dispose()
        logger.info("Device Service shutting down...")


app = FastAPI(
    title="Device Service",
    description="Manages device registration and shadow state, backed by Postgres",
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

@app.get("/health", tags=["Health"])
async def health_check():
    return {
        "status": "healthy",
        "service": "device-service",
        "timestamp": datetime.utcnow().isoformat(),
    }


@app.get("/api/v1/device/info", tags=["Info"])
async def service_info(session: AsyncSession = Depends(get_session)):
    devices = (await session.execute(select(Device))).scalars().all()
    return {
        "service": "device-service",
        "instance": socket.gethostname(),
        "version": "3.0.0",
        "integrations": {
            "tuya_bridge": bool(TUYA_BRIDGE_URL),
            "sqs_events": bool(DEVICE_EVENTS_QUEUE),
        },
        "device_count": len(devices),
        "device_types": len(device_types_db),
    }


# =============================================================================
# Device Type Endpoints
# =============================================================================

@app.get("/api/v1/device/types", tags=["Device Types"])
async def list_device_types():
    return {"device_types": list(device_types_db.values())}


@app.get("/api/v1/device/types/{type_id}", tags=["Device Types"])
async def get_device_type(type_id: str):
    if type_id not in device_types_db:
        raise HTTPException(status_code=404, detail="Device type not found")
    return device_types_db[type_id]


# =============================================================================
# Device CRUD
# =============================================================================

@app.get("/api/v1/device/devices", tags=["Devices"])
async def list_devices(
    room: Optional[str] = Query(None),
    online: Optional[bool] = Query(None),
    session: AsyncSession = Depends(get_session),
):
    stmt = select(Device)
    if room is not None:
        stmt = stmt.where(Device.room == room)
    if online is not None:
        stmt = stmt.where(Device.online == online)
    devices = (await session.execute(stmt)).scalars().all()
    return {"devices": devices, "total": len(devices)}


@app.post("/api/v1/device/devices", tags=["Devices"], status_code=201)
async def create_device(
    device_create: DeviceCreate,
    session: AsyncSession = Depends(get_session),
):
    if device_create.device_type_id not in device_types_db:
        raise HTTPException(status_code=400, detail="Invalid device type")

    if device_create.tuya_device_id:
        existing = (await session.execute(
            select(Device).where(Device.tuya_device_id == device_create.tuya_device_id)
        )).scalar_one_or_none()
        if existing:
            existing.name = device_create.name
            if device_create.room is not None:
                existing.room = device_create.room
            session.add(existing)
            await session.commit()
            await session.refresh(existing)
            return existing

    device_type = device_types_db[device_create.device_type_id]
    device_id = f"device-{uuid.uuid4().hex[:8]}"

    initial_envelope = {
        "desired": {},
        "reported": dict(device_type.default_state),
        "version": 0,
        "retry_count": 0,
        "last_attempted": None,
    }

    device = Device(
        id=device_id,
        name=device_create.name,
        device_type_id=device_create.device_type_id,
        tuya_device_id=device_create.tuya_device_id,
        room=device_create.room,
        state=initial_envelope,
        online=False,
    )
    session.add(device)
    await session.commit()
    await session.refresh(device)

    await publish_device_event("device.created", device)
    return device


@app.get("/api/v1/device/devices/{device_id}", tags=["Devices"])
async def get_device(device_id: str, session: AsyncSession = Depends(get_session)):
    device = await session.get(Device, device_id)
    if not device:
        raise HTTPException(status_code=404, detail="Device not found")
    return device


@app.delete("/api/v1/device/devices/{device_id}", tags=["Devices"])
async def delete_device(device_id: str, session: AsyncSession = Depends(get_session)):
    device = await session.get(Device, device_id)
    if not device:
        raise HTTPException(status_code=404, detail="Device not found")

    await publish_device_event("device.deleted", device)
    await session.delete(device)
    await session.commit()
    return {"message": f"Device {device_id} deleted"}


# =============================================================================
# Device State & Control
# =============================================================================

@app.get("/api/v1/device/devices/{device_id}/state", tags=["Device State"])
async def get_device_state(device_id: str, session: AsyncSession = Depends(get_session)):
    device = await session.get(Device, device_id)
    if not device:
        raise HTTPException(status_code=404, detail="Device not found")

    env = _envelope(device.state)
    return {
        "state": _merged_view(env),
        "desired": env["desired"],
        "reported": env["reported"],
        "version": env["version"],
        "source": "postgres",
    }


def _apply_desired(state_update: dict):
    """Mutate factory: merge state_update into desired and reset retry
    tracking (new command supersedes any prior pending state)."""
    def mutate(env: dict) -> dict:
        return {
            "desired": {**env["desired"], **state_update},
            "reported": env["reported"],
            "version": env["version"],
            "retry_count": 0,
            "last_attempted": None,
        }
    return mutate


@app.put("/api/v1/device/devices/{device_id}/state", tags=["Device State"])
async def update_device_state(
    device_id: str,
    update: DeviceStateUpdate,
    session: AsyncSession = Depends(get_session),
):
    device, new_env = await _save_envelope(session, device_id, _apply_desired(update.state))

    # Optimistic online flag — caller just touched this device, so we know
    # it's alive from the platform's perspective even before the bridge
    # confirms via reported state.
    if not device.online:
        device.online = True
        device.last_seen = datetime.utcnow()
        session.add(device)
        await session.commit()

    if device.tuya_device_id:
        await dispatch_command(device.tuya_device_id, update.state)

    await publish_device_event("device.state_changed", device, update.state)
    return {"device_id": device_id, "state": _merged_view(new_env),
            "desired": new_env["desired"], "reported": new_env["reported"],
            "version": new_env["version"]}


@app.post("/api/v1/device/devices/{device_id}/command", tags=["Device Control"])
async def send_device_command(
    device_id: str,
    command: CommandRequest,
    session: AsyncSession = Depends(get_session),
):
    state_update = {command.command: command.value}
    device, _new_env = await _save_envelope(session, device_id, _apply_desired(state_update))

    if not device.online:
        device.online = True
        device.last_seen = datetime.utcnow()
        session.add(device)
        await session.commit()

    if device.tuya_device_id:
        await dispatch_command(device.tuya_device_id, state_update)

    await publish_device_event("device.command", device, {
        "command": command.command,
        "value": command.value,
    })

    return {
        "device_id": device_id,
        "command": command.command,
        "value": command.value,
        "success": True,
    }


# =============================================================================
# Convenience endpoints
# =============================================================================

@app.post("/api/v1/device/devices/{device_id}/on", tags=["Quick Controls"])
async def turn_device_on(device_id: str, session: AsyncSession = Depends(get_session)):
    return await send_device_command(device_id, CommandRequest(command="switch_led", value=True), session)


@app.post("/api/v1/device/devices/{device_id}/off", tags=["Quick Controls"])
async def turn_device_off(device_id: str, session: AsyncSession = Depends(get_session)):
    return await send_device_command(device_id, CommandRequest(command="switch_led", value=False), session)


@app.post("/api/v1/device/devices/{device_id}/brightness", tags=["Quick Controls"])
async def set_brightness(
    device_id: str,
    level: int = Query(..., ge=10, le=1000),
    session: AsyncSession = Depends(get_session),
):
    return await send_device_command(device_id, CommandRequest(command="bright_value_v2", value=level), session)


# =============================================================================
# Internal endpoints (called by tuya-bridge)
# =============================================================================

@app.post("/api/v1/device/internal/reported", include_in_schema=False)
async def receive_reported_state(
    payload: ReportedStateUpdate,
    session: AsyncSession = Depends(get_session),
    _: None = Depends(require_internal_token),
):
    """Bridge pushes reported state after Tuya success or poll tick.
    Clears any desired keys whose reported value now matches."""
    device = (await session.execute(
        select(Device).where(Device.tuya_device_id == payload.tuya_device_id)
    )).scalar_one_or_none()
    if not device:
        return {"status": "unknown_device"}

    def mutate(env: dict) -> dict:
        # Merge incoming reported into existing reported first, then drop
        # desired keys whose new reported value matches — comparison must
        # use the *merged* view, not the pre-merge env.
        new_reported = {**env["reported"], **payload.reported}
        new_desired = {
            k: v for k, v in env["desired"].items()
            if new_reported.get(k) != v
        }
        # Retry tracking reset rule: only clear on FULL convergence. If
        # Tuya partially applied the command and `new_desired` retains
        # some keys, keep the counter so we know how many attempts have
        # already gone into this (still-failing) command.
        retry_count = 0 if not new_desired else env.get("retry_count", 0)
        last_attempted = None if not new_desired else env.get("last_attempted")
        return {
            "desired": new_desired,
            "reported": new_reported,
            "version": env["version"],
            "retry_count": retry_count,
            "last_attempted": last_attempted,
        }

    device, new_env = await _save_envelope(session, device.id, mutate)

    device.online = True
    device.last_seen = datetime.utcnow()
    session.add(device)
    await session.commit()
    return {"status": "ok", "version": new_env["version"]}


@app.post("/api/v1/device/internal/pending", include_in_schema=False)
async def claim_pending_devices(
    session: AsyncSession = Depends(get_session),
    _: None = Depends(require_internal_token),
):
    """Atomically claim a batch of devices with stuck desired state for
    retry by the bridge. Filters out:
      - devices whose desired is empty
      - devices attempted within the last PENDING_BACKOFF_SECONDS
      - devices that have hit PENDING_MAX_RETRIES (operator must re-PUT
        to reset)
    Bumps retry_count and last_attempted on the way out so concurrent
    bridge replicas don't double-process the same device.

    POST rather than GET because the read has side effects (the
    bookkeeping fields).
    """
    now = int(time.time())
    backoff_cutoff = now - PENDING_BACKOFF_SECONDS

    devices = (await session.execute(
        select(Device).where(Device.tuya_device_id.is_not(None))
    )).scalars().all()

    claimed = []
    for device in devices:
        env = _envelope(device.state)
        if not env["desired"]:
            continue
        if env["retry_count"] >= PENDING_MAX_RETRIES:
            continue
        last = env.get("last_attempted")
        if last is not None and last > backoff_cutoff:
            continue

        def mutate(e: dict) -> dict:
            return {
                "desired": e["desired"],
                "reported": e["reported"],
                "version": e["version"],
                "retry_count": e.get("retry_count", 0) + 1,
                "last_attempted": now,
            }

        try:
            _device, new_env = await _save_envelope(session, device.id, mutate)
        except HTTPException:
            # Lost the OCC race to another writer; skip and let the next
            # poll pick it up.
            continue

        claimed.append({
            "tuya_device_id": device.tuya_device_id,
            "desired": new_env["desired"],
            "version": new_env["version"],
            "retry_count": new_env["retry_count"],
        })

    return {"pending": claimed}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8001)
