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
from typing import Any, Callable, Optional

import httpx
from fastapi import Depends, FastAPI, Header, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field as PydanticField
from sqlalchemy import BigInteger, Column, DateTime, Float, ForeignKey, Index, Integer, cast, text
from sqlalchemy import update as sa_update
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import Field, SQLModel, select

from shared.cloud import event_bus

from .db import engine, get_session, init_db

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO").upper())
logger = logging.getLogger(__name__)

# =============================================================================
# Configuration
# =============================================================================

TUYA_BRIDGE_URL = os.getenv("TUYA_BRIDGE_URL", "").rstrip("/")
INTERNAL_TOKEN = os.getenv("INTERNAL_TOKEN", "")

# Retry policy for stuck desired-state commands. The tuya-bridge polls
# /internal/pending each tick; this endpoint filters by these bounds so a
# permanently-failing command can't re-fire forever.
PENDING_MAX_RETRIES = int(os.getenv("PENDING_MAX_RETRIES", "5"))
PENDING_BACKOFF_SECONDS = int(os.getenv("PENDING_BACKOFF_SECONDS", "60"))

_event_bus = None
http_client: Optional[httpx.AsyncClient] = None


def get_event_bus():
    global _event_bus
    if _event_bus is None:
        _event_bus = event_bus()
    return _event_bus


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
    # Per-device-class static metadata (e.g. {"subtype": "shelly_ht_gen3"}).
    # Distinct from `state` — `state` is the live shadow, `device_metadata`
    # is registration-time vendor info that doesn't change at runtime.
    # Named `device_metadata` rather than `metadata` because SQLAlchemy
    # reserves `metadata` for the declarative-class registry; the SQL
    # column and JSON field both use `device_metadata` for consistency.
    device_metadata: dict = Field(
        default_factory=dict,
        sa_column=Column(JSONB, nullable=False,
                         server_default=text("'{}'::jsonb")),
    )
    online: bool = False
    last_seen: Optional[datetime] = None
    created_at: datetime = Field(default_factory=datetime.utcnow)


class DeviceKey(SQLModel, table=True):
    """Per-device API key for the protocol/v1/* endpoints. Plaintext is
    returned once at issuance; only the bcrypt hash is persisted. Scopes
    gate which protocol endpoints the key can hit (the inherited
    `device-protocol-design.md` defines read_pending/write_reported for
    polling devices; this PR adds the schema, but write_telemetry — the
    Shelly scope — is enforced by the receive endpoint in a later PR)."""
    __tablename__ = "device_keys"
    id: str = Field(
        default_factory=lambda: str(uuid.uuid4()),
        primary_key=True,
    )
    device_id: str = Field(
        sa_column=Column(
            ForeignKey("devices.id", ondelete="CASCADE"),
            nullable=False,
            index=True,
        ),
    )
    key_hash: str  # bcrypt of the issued plaintext key
    key_prefix: str  # first ~8 chars of plaintext for UI display hints
    scopes: list[str] = Field(
        default_factory=lambda: ["read_pending", "write_reported"],
        sa_column=Column(
            JSONB,
            nullable=False,
            server_default=text("'[\"read_pending\", \"write_reported\"]'::jsonb"),
        ),
    )
    created_at: datetime = Field(default_factory=datetime.utcnow)
    last_used_at: Optional[datetime] = None
    revoked_at: Optional[datetime] = None


class DeviceTelemetry(SQLModel, table=True):
    """One row per (device, capability, reading). Long format because
    `WHERE capability='temperature'` and per-capability aggregations are
    the dominant query shape, and the row volume from sleep-cycle sensors
    is trivial (~48 rows/device/day at default H&T cadence).

    `recorded_at` is the device-supplied timestamp (NULL when the device
    omits it — by design, distinguishes device-stamped from server-
    stamped provenance). The partial unique index on (device_id,
    capability, recorded_at) WHERE recorded_at IS NOT NULL lets the
    receive endpoint use INSERT ... ON CONFLICT DO NOTHING to absorb
    retried Shelly webhooks idempotently for the device-stamped case.
    No `unit` column — the unit is recoverable from `capability` via
    the CAPABILITIES registry."""
    __tablename__ = "device_telemetry"
    __table_args__ = (
        Index(
            "ix_telemetry_device_capability_received",
            "device_id", "capability", "received_at",
        ),
        Index(
            "uq_telemetry_recorded",
            "device_id", "capability", "recorded_at",
            unique=True,
            postgresql_where=text("recorded_at IS NOT NULL"),
        ),
    )
    id: Optional[int] = Field(
        default=None,
        sa_column=Column(BigInteger, primary_key=True, autoincrement=True),
    )
    device_id: str = Field(
        sa_column=Column(
            ForeignKey("devices.id", ondelete="CASCADE"),
            nullable=False,
        ),
    )
    capability: str
    value: float = Field(sa_column=Column(Float, nullable=False))
    # timestamptz so device-supplied and server-stamped timestamps are
    # comparable across timezones. Inherited `devices.created_at` is
    # naive TIMESTAMP; deliberately not migrating that here.
    recorded_at: Optional[datetime] = Field(
        default=None,
        sa_column=Column(DateTime(timezone=True), nullable=True),
    )
    received_at: datetime = Field(
        default_factory=datetime.utcnow,
        sa_column=Column(
            DateTime(timezone=True),
            nullable=False,
            server_default=text("now()"),
        ),
    )


class DeviceCreate(BaseModel):
    name: str
    device_type_id: str
    tuya_device_id: Optional[str] = None
    room: Optional[str] = None


class DeviceStateUpdate(BaseModel):
    state: dict


class CommandRequest(BaseModel):
    capability: str
    value: Any


class ReportedStateUpdate(BaseModel):
    tuya_device_id: str
    reported: dict


# =============================================================================
# Canonical capability vocabulary
# =============================================================================
# The platform API speaks these names only. Vendor-specific translation
# (Tuya datapoint codes, value-range scaling, etc.) lives in each adapter.
# Adding a new capability here is the only place a new device feature
# needs to be defined at the platform layer.

CAPABILITIES = {
    "power": {
        "type": "bool",
        "description": "On/off state",
    },
    "brightness": {
        "type": "int",
        "range": [0, 100],
        "unit": "percent",
        # Note: brightness 0 is clamped to ~1% on most hardware (Tuya
        # minimum is 10/1000). Use `power: false` to actually turn off.
        "description": "Brightness as a percentage of device maximum",
    },
    "color": {
        "type": "object",
        "schema": {
            "h": {"range": [0, 360], "unit": "degrees"},
            "s": {"range": [0, 100], "unit": "percent"},
            "v": {"range": [0, 100], "unit": "percent"},
        },
        "description": "Color as HSV with normalized 0-100 saturation/value",
    },
    "color_temp": {
        "type": "int",
        "range": [0, 100],
        "unit": "percent",
        "description": "Color temperature, 0 = warmest, 100 = coolest",
    },
    "mode": {
        "type": "string",
        "enum": ["white", "colour", "scene", "music"],
        "description": "Bulb operating mode",
    },
    # Sensor capabilities. Registered here in PR1 so the 'sensor' device
    # type can declare them without tripping _sanity_check_device_types.
    # The `read_only` flag and PUT /state rejection land in a later PR
    # alongside the protocol/v1/telemetry receive endpoint.
    "temperature": {
        "type": "float",
        "range": [-40.0, 180.0],
        "unit": "fahrenheit",
        "description": "Ambient temperature in Fahrenheit",
    },
    "humidity": {
        "type": "float",
        "range": [0.0, 100.0],
        "unit": "percent",
        "description": "Relative humidity as a percentage",
    },
}

# Keys allowed in `reported` state that aren't capabilities — metadata
# the bridge sets to help operators reason about freshness.
_REPORTED_METADATA_KEYS = {"last_sync"}


def _validate_value(capability: str, value) -> None:
    spec = CAPABILITIES.get(capability)
    if not spec:
        return  # name already gated by validate_state_keys
    t = spec.get("type")
    if t == "bool":
        if not isinstance(value, bool):
            raise HTTPException(status_code=400,
                                detail=f"{capability} must be a bool")
    elif t == "int":
        # bool is a subclass of int in Python; explicitly disallow.
        if isinstance(value, bool) or not isinstance(value, int):
            raise HTTPException(status_code=400,
                                detail=f"{capability} must be an int")
        rng = spec.get("range")
        if rng and not (rng[0] <= value <= rng[1]):
            raise HTTPException(status_code=400,
                                detail=f"{capability} must be in {rng}, got {value}")
    elif t == "float":
        # Accept int as a valid float; reject bool (subclass of int).
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise HTTPException(status_code=400,
                                detail=f"{capability} must be a number")
        rng = spec.get("range")
        if rng and not (rng[0] <= float(value) <= rng[1]):
            raise HTTPException(status_code=400,
                                detail=f"{capability} must be in {rng}, got {value}")
    elif t == "string":
        if not isinstance(value, str):
            raise HTTPException(status_code=400,
                                detail=f"{capability} must be a string")
        enum = spec.get("enum")
        if enum and value not in enum:
            raise HTTPException(status_code=400,
                                detail=f"{capability} must be one of {enum}")
    elif t == "object":
        if not isinstance(value, dict):
            raise HTTPException(status_code=400,
                                detail=f"{capability} must be an object")
        schema = spec.get("schema") or {}
        unknown_subs = [k for k in value.keys() if k not in schema]
        if unknown_subs:
            raise HTTPException(
                status_code=400,
                detail=f"{capability} has unknown sub-keys: {unknown_subs}. "
                       f"Allowed: {sorted(schema.keys())}",
            )
        for sub_key, sub_spec in schema.items():
            sub_val = value.get(sub_key)
            if sub_val is None:
                continue  # absent sub-keys are OK — see _deep_merge_capabilities
            if isinstance(sub_val, bool) or not isinstance(sub_val, int):
                raise HTTPException(status_code=400,
                                    detail=f"{capability}.{sub_key} must be an int")
            sub_rng = sub_spec.get("range")
            if sub_rng and not (sub_rng[0] <= sub_val <= sub_rng[1]):
                raise HTTPException(status_code=400,
                                    detail=f"{capability}.{sub_key} must be in {sub_rng}, got {sub_val}")


def _deep_merge_capabilities(existing: dict, update: dict) -> dict:
    """Merge `update` into `existing`. For keys whose capability spec is
    `type: object`, merge sub-keys (so `{"color": {"h": 200}}` doesn't
    blow away the existing `s` and `v`). Everything else is shallow-
    replaced, matching the historical semantics of the API."""
    result = dict(existing)
    for key, value in update.items():
        spec = CAPABILITIES.get(key)
        is_object_merge = (
            spec is not None
            and spec.get("type") == "object"
            and isinstance(value, dict)
            and isinstance(result.get(key), dict)
        )
        if is_object_merge:
            result[key] = {**result[key], **value}
        else:
            result[key] = value
    return result


def validate_state_keys(state: dict, device_type: DeviceType) -> None:
    """Reject any state that doesn't match the device type's capabilities.
    Keys must be in the type's capability list; values must match the
    type / range / enum declared in CAPABILITIES. Catches typos, leftover
    vendor codes, and malformed input at the API edge instead of letting
    them propagate into the shadow."""
    allowed = set(device_type.capabilities)
    bad = [k for k in state.keys() if k not in allowed]
    if bad:
        raise HTTPException(
            status_code=400,
            detail=f"Unknown capabilities for {device_type.id}: {bad}. "
                   f"Allowed: {sorted(allowed)}",
        )
    for k, v in state.items():
        _validate_value(k, v)


# =============================================================================
# Seeded Device Type Templates
# =============================================================================

device_types_db: dict[str, DeviceType] = {
    "tuya-smart-bulb": DeviceType(
        id="tuya-smart-bulb",
        name="Tuya Smart Bulb",
        manufacturer="MAXvolador",
        capabilities=["power", "brightness", "color", "color_temp", "mode"],
        default_state={
            "power": False,
            "brightness": 50,
            "color": {"h": 0, "s": 0, "v": 100},
            "mode": "white",
        },
    ),
    "tuya-smart-plug": DeviceType(
        id="tuya-smart-plug",
        name="Tuya Smart Plug",
        manufacturer="Generic",
        capabilities=["power"],
        default_state={"power": False},
    ),
    # Generic sensor type — per the design doc, the device class is
    # 'sensor' at the type level and vendor-specific identity lives in
    # the per-device `device_metadata` jsonb column
    # (e.g. {"subtype": "shelly_ht_gen3"}). default_state is empty
    # because sensor readings are recorded in the device_telemetry
    # table, not in the shadow envelope.
    "sensor": DeviceType(
        id="sensor",
        name="Environmental Sensor",
        manufacturer="Generic",
        capabilities=["temperature", "humidity"],
        default_state={},
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
    mutate: Callable[[dict], dict],
    max_retries: int = 3,
    validate: Optional[Callable[["Device"], None]] = None,
) -> tuple["Device", dict]:
    """Apply `mutate(env) -> new_env` to a device's shadow envelope with
    optimistic concurrency. Re-reads on version conflict; raises 409 after
    `max_retries` consecutive conflicts. Returns the (device, new_env)
    pair — callers should use the returned Device rather than re-fetching,
    since the bulk UPDATE bypasses the ORM identity map and a follow-up
    session.get() may return stale state.

    `validate(device)` (optional) is invoked on the first read each
    iteration, before the mutate runs. Use it for input validation that
    needs device context (e.g., capability checks). Idempotent across
    retries — device.device_type_id doesn't change."""
    for _ in range(max_retries):
        stmt = (
            select(Device)
            .where(Device.id == device_id)
            .execution_options(populate_existing=True)
        )
        device = (await session.execute(stmt)).scalar_one_or_none()
        if not device:
            raise HTTPException(status_code=404, detail="Device not found")

        if validate is not None:
            validate(device)

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
# Event publishing
# =============================================================================

async def publish_device_event(event_type: str, device: Device, data: dict = None):
    bus = get_event_bus()
    message = {
        "event_type": event_type,
        "device_id": device.id,
        "device_name": device.name,
        "timestamp": datetime.utcnow().isoformat(),
        "data": data or {},
    }
    try:
        await bus.publish(message, attributes={"event_type": event_type})
    except Exception as e:  # noqa: BLE001
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

def _sanity_check_device_types() -> None:
    """Fail fast if a DeviceType declares a capability that isn't in
    CAPABILITIES — catches typos in seed data instead of letting them
    surface as a 400 on first user request."""
    for type_id, dt in device_types_db.items():
        bad = [c for c in dt.capabilities if c not in CAPABILITIES]
        if bad:
            raise RuntimeError(
                f"DeviceType {type_id} declares unknown capabilities: {bad}. "
                f"Add to CAPABILITIES or remove from the type definition."
            )


@asynccontextmanager
async def lifespan(app: FastAPI):
    global http_client
    http_client = httpx.AsyncClient()
    _sanity_check_device_types()
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
            "event_bus": os.environ.get("CLOUD_PROVIDER", "none"),
        },
        "device_count": len(devices),
        "device_types": len(device_types_db),
    }


# =============================================================================
# Device Type Endpoints
# =============================================================================

@app.get("/api/v1/device/capabilities", tags=["Device Types"])
async def list_capabilities():
    """The canonical capability vocabulary supported by the platform.
    Clients (and device firmware) should consult this rather than
    hardcoding capability names."""
    return {"capabilities": CAPABILITIES}


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
    tracking (new command supersedes any prior pending state). Object
    capabilities deep-merge — partial writes preserve untouched sub-keys."""
    def mutate(env: dict) -> dict:
        return {
            "desired": _deep_merge_capabilities(env["desired"], state_update),
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
    def _validate(dev: Device) -> None:
        device_type = device_types_db.get(dev.device_type_id)
        if device_type:
            validate_state_keys(update.state, device_type)

    device, new_env = await _save_envelope(
        session, device_id, _apply_desired(update.state), validate=_validate
    )

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
    state_update = {command.capability: command.value}

    def _validate(dev: Device) -> None:
        device_type = device_types_db.get(dev.device_type_id)
        if device_type:
            validate_state_keys(state_update, device_type)

    device, _new_env = await _save_envelope(
        session, device_id, _apply_desired(state_update), validate=_validate
    )

    if not device.online:
        device.online = True
        device.last_seen = datetime.utcnow()
        session.add(device)
        await session.commit()

    if device.tuya_device_id:
        await dispatch_command(device.tuya_device_id, state_update)

    await publish_device_event("device.command", device, {
        "capability": command.capability,
        "value": command.value,
    })

    return {
        "device_id": device_id,
        "capability": command.capability,
        "value": command.value,
        "success": True,
    }


# =============================================================================
# Convenience endpoints — write canonical capability names
# =============================================================================

@app.post("/api/v1/device/devices/{device_id}/on", tags=["Quick Controls"])
async def turn_device_on(device_id: str, session: AsyncSession = Depends(get_session)):
    return await send_device_command(device_id, CommandRequest(capability="power", value=True), session)


@app.post("/api/v1/device/devices/{device_id}/off", tags=["Quick Controls"])
async def turn_device_off(device_id: str, session: AsyncSession = Depends(get_session)):
    return await send_device_command(device_id, CommandRequest(capability="power", value=False), session)


@app.post("/api/v1/device/devices/{device_id}/brightness", tags=["Quick Controls"])
async def set_brightness(
    device_id: str,
    level: int = Query(..., ge=0, le=100, description="Brightness percent, 0-100"),
    session: AsyncSession = Depends(get_session),
):
    return await send_device_command(device_id, CommandRequest(capability="brightness", value=level), session)


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

    # Internal endpoints don't run the public validate_state_keys path —
    # bridges are trusted to translate vendor data into canonical form
    # before posting. We do still filter the merged reported by the
    # device type's capability list (plus metadata keys) on the way in:
    # cheap defense against a buggy adapter, and the one-shot cleanup
    # that strips Tuya-coded keys from legacy rows written before the
    # vocabulary abstraction landed.
    #
    # Capability coverage is constrained by the *intersection* of
    # bridge translation and seed-data declaration: if a bridge knows
    # how to emit a canonical key that's not in the device type's
    # capabilities list, the platform silently drops it. Keep
    # CAPABILITIES, the bridge translator (canonical_to_tuya /
    # tuya_status_to_canonical), and DeviceType.capabilities in sync
    # when adding features.
    device_type = device_types_db.get(device.device_type_id)
    allowed_reported = (set(device_type.capabilities) | _REPORTED_METADATA_KEYS
                        if device_type else None)

    def mutate(env: dict) -> dict:
        # Deep-merge so partial reported updates (e.g. `{"color": {"h":
        # 200}}` from the bridge's optimistic post) don't wipe sub-keys.
        new_reported = _deep_merge_capabilities(env["reported"], payload.reported)
        if allowed_reported is not None:
            new_reported = {k: v for k, v in new_reported.items()
                            if k in allowed_reported}
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
