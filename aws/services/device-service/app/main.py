"""
Device Service
==============
Manages device registration, state, and IoT Core integration.

Storage: Postgres for devices. Device types are immutable seed data kept in-memory.
"""

import os
import uuid
import json
import socket
import logging
from datetime import datetime
from typing import Optional, Any
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Depends, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field as PydanticField
from sqlalchemy import Column, text
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import Field, SQLModel, select
import boto3
from botocore.exceptions import ClientError

from .db import engine, get_session, init_db

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# =============================================================================
# Configuration
# =============================================================================

IOT_ENDPOINT = os.getenv("IOT_ENDPOINT", "")
DEVICE_EVENTS_QUEUE = os.getenv("DEVICE_EVENTS_QUEUE", "")
AWS_REGION = os.getenv("AWS_REGION", "us-east-1")

iot_client = None
sqs_client = None


def get_iot_client():
    global iot_client
    if iot_client is None and IOT_ENDPOINT:
        iot_client = boto3.client('iot-data',
                                   region_name=AWS_REGION,
                                   endpoint_url=f"https://{IOT_ENDPOINT}")
    return iot_client


def get_sqs_client():
    global sqs_client
    if sqs_client is None:
        sqs_client = boto3.client('sqs', region_name=AWS_REGION)
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
    state: dict = Field(default_factory=dict, sa_column=Column(JSONB, nullable=False, server_default=text("'{}'::jsonb")))
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
# IoT Core Integration (unchanged from in-memory version)
# =============================================================================

async def get_device_shadow(thing_name: str) -> Optional[dict]:
    client = get_iot_client()
    if not client:
        return None
    try:
        response = client.get_thing_shadow(thingName=thing_name)
        payload = json.loads(response['payload'].read())
        return payload.get('state', {}).get('reported', {})
    except ClientError as e:
        if e.response['Error']['Code'] == 'ResourceNotFoundException':
            return None
        logger.error(f"Error getting shadow: {e}")
        raise


async def update_device_shadow(thing_name: str, desired_state: dict) -> dict:
    client = get_iot_client()
    if not client:
        return desired_state
    payload = {"state": {"desired": desired_state}}
    try:
        client.update_thing_shadow(
            thingName=thing_name,
            payload=json.dumps(payload).encode('utf-8'),
        )
        return desired_state
    except ClientError as e:
        logger.error(f"Error updating shadow: {e}")
        raise HTTPException(status_code=500, detail=f"IoT Core error: {str(e)}")


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
        client.send_message(
            QueueUrl=DEVICE_EVENTS_QUEUE,
            MessageBody=json.dumps(message),
            MessageAttributes={
                "event_type": {"DataType": "String", "StringValue": event_type}
            },
        )
    except ClientError as e:
        logger.error(f"Error publishing event: {e}")


# =============================================================================
# Application
# =============================================================================

@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Device Service starting...")
    await init_db()
    yield
    await engine.dispose()
    logger.info("Device Service shutting down...")


app = FastAPI(
    title="Device Service",
    description="Manages device registration and state via AWS IoT Core",
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
        "version": "2.0.0",
        "aws_integration": {
            "iot_core": bool(IOT_ENDPOINT),
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

    device_type = device_types_db[device_create.device_type_id]
    device_id = f"device-{uuid.uuid4().hex[:8]}"

    device = Device(
        id=device_id,
        name=device_create.name,
        device_type_id=device_create.device_type_id,
        tuya_device_id=device_create.tuya_device_id,
        room=device_create.room,
        state=dict(device_type.default_state),
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

    if device.tuya_device_id and IOT_ENDPOINT:
        thing_name = f"tuya-{device.tuya_device_id}"
        shadow_state = await get_device_shadow(thing_name)
        if shadow_state:
            device.state = shadow_state
            device.online = True
            device.last_seen = datetime.utcnow()
            session.add(device)
            await session.commit()
            await session.refresh(device)

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

    if device.tuya_device_id and IOT_ENDPOINT:
        thing_name = f"tuya-{device.tuya_device_id}"
        shadow_state = await get_device_shadow(thing_name)
        if shadow_state:
            return {"state": shadow_state, "source": "iot_core"}

    return {"state": device.state, "source": "local"}


@app.put("/api/v1/device/devices/{device_id}/state", tags=["Device State"])
async def update_device_state(
    device_id: str,
    update: DeviceStateUpdate,
    session: AsyncSession = Depends(get_session),
):
    device = await session.get(Device, device_id)
    if not device:
        raise HTTPException(status_code=404, detail="Device not found")

    if device.tuya_device_id and IOT_ENDPOINT:
        thing_name = f"tuya-{device.tuya_device_id}"
        await update_device_shadow(thing_name, update.state)

    merged = dict(device.state or {})
    merged.update(update.state)
    device.state = merged
    session.add(device)
    await session.commit()
    await session.refresh(device)

    await publish_device_event("device.state_changed", device, update.state)
    return {"device_id": device_id, "state": device.state}


@app.post("/api/v1/device/devices/{device_id}/command", tags=["Device Control"])
async def send_device_command(
    device_id: str,
    command: CommandRequest,
    session: AsyncSession = Depends(get_session),
):
    device = await session.get(Device, device_id)
    if not device:
        raise HTTPException(status_code=404, detail="Device not found")

    state_update = {command.command: command.value}

    if device.tuya_device_id and IOT_ENDPOINT:
        thing_name = f"tuya-{device.tuya_device_id}"
        await update_device_shadow(thing_name, state_update)

    merged = dict(device.state or {})
    merged.update(state_update)
    device.state = merged
    session.add(device)
    await session.commit()

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


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8001)
