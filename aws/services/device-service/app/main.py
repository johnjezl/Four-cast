"""
Device Service
==============
Manages device registration, state, and IoT Core integration.

Textbook Reference:
- Ch. 3: Self-service API for device management
- Ch. 3: Integration with managed IoT services (AWS IoT Core)

AWS Services Used:
- IoT Core: Device shadows for state management
- SQS: Event-driven updates to other services
"""

import os
import json
import logging
from datetime import datetime
from typing import Optional
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
import boto3
from botocore.exceptions import ClientError

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# =============================================================================
# Configuration
# =============================================================================

IOT_ENDPOINT = os.getenv("IOT_ENDPOINT", "")
DEVICE_EVENTS_QUEUE = os.getenv("DEVICE_EVENTS_QUEUE", "")
AWS_REGION = os.getenv("AWS_REGION", "us-east-1")

# AWS Clients (initialized lazily for local development)
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
# Data Models
# =============================================================================

class DeviceType(BaseModel):
    """Template for a category of devices."""
    id: str
    name: str
    manufacturer: str
    capabilities: list[str] = Field(default_factory=list)
    default_state: dict = Field(default_factory=dict)


class Device(BaseModel):
    """Registered device instance."""
    id: str
    name: str
    device_type_id: str
    tuya_device_id: Optional[str] = None
    room: Optional[str] = None
    state: dict = Field(default_factory=dict)
    online: bool = False
    last_seen: Optional[datetime] = None
    created_at: datetime = Field(default_factory=datetime.utcnow)


class DeviceCreate(BaseModel):
    """Request body for creating a device."""
    name: str
    device_type_id: str
    tuya_device_id: Optional[str] = None
    room: Optional[str] = None


class DeviceStateUpdate(BaseModel):
    """Request body for updating device state."""
    state: dict


class CommandRequest(BaseModel):
    """Request body for sending commands."""
    command: str  # e.g., "switch_led", "set_brightness"
    value: any    # e.g., True, 500, {"h": 120, "s": 255, "v": 255}


# =============================================================================
# In-Memory Storage (replace with RDS in production)
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
            "work_mode": "white"
        }
    ),
    "tuya-smart-plug": DeviceType(
        id="tuya-smart-plug",
        name="Tuya Smart Plug",
        manufacturer="Generic",
        capabilities=["switch", "energy_monitoring"],
        default_state={
            "switch": False,
            "cur_power": 0,
            "cur_voltage": 0
        }
    )
}

devices_db: dict[str, Device] = {}


# =============================================================================
# IoT Core Integration
# =============================================================================

async def get_device_shadow(thing_name: str) -> Optional[dict]:
    """Get device state from IoT Core shadow."""
    client = get_iot_client()
    if not client:
        logger.warning("IoT client not configured")
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
    """
    Update IoT Core shadow with desired state.
    
    This triggers the IoT Rule → Lambda → Tuya flow to control the physical device.
    """
    client = get_iot_client()
    if not client:
        logger.warning("IoT client not configured, using local state only")
        return desired_state
    
    payload = {
        "state": {
            "desired": desired_state
        }
    }
    
    try:
        response = client.update_thing_shadow(
            thingName=thing_name,
            payload=json.dumps(payload).encode('utf-8')
        )
        logger.info(f"Updated shadow for {thing_name}: {desired_state}")
        return desired_state
    except ClientError as e:
        logger.error(f"Error updating shadow: {e}")
        raise HTTPException(status_code=500, detail=f"IoT Core error: {str(e)}")


async def publish_device_event(event_type: str, device: Device, data: dict = None):
    """Publish device event to SQS for other services."""
    client = get_sqs_client()
    if not client or not DEVICE_EVENTS_QUEUE:
        logger.warning("SQS not configured, skipping event publish")
        return
    
    message = {
        "event_type": event_type,
        "device_id": device.id,
        "device_name": device.name,
        "timestamp": datetime.utcnow().isoformat(),
        "data": data or {}
    }
    
    try:
        client.send_message(
            QueueUrl=DEVICE_EVENTS_QUEUE,
            MessageBody=json.dumps(message),
            MessageAttributes={
                "event_type": {
                    "DataType": "String",
                    "StringValue": event_type
                }
            }
        )
        logger.info(f"Published event: {event_type} for device {device.id}")
    except ClientError as e:
        logger.error(f"Error publishing event: {e}")


# =============================================================================
# Application Lifecycle
# =============================================================================

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application startup and shutdown."""
    logger.info("Device Service starting up...")
    logger.info(f"IoT Endpoint: {IOT_ENDPOINT or 'Not configured'}")
    logger.info(f"Events Queue: {DEVICE_EVENTS_QUEUE or 'Not configured'}")
    yield
    logger.info("Device Service shutting down...")


# =============================================================================
# FastAPI Application
# =============================================================================

app = FastAPI(
    title="Device Service",
    description="Manages device registration and state via AWS IoT Core",
    version="1.0.0",
    lifespan=lifespan
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# =============================================================================
# Health & Info Endpoints
# =============================================================================

@app.get("/health", tags=["Health"])
async def health_check():
    """Health check endpoint for ALB."""
    return {
        "status": "healthy",
        "service": "device-service",
        "timestamp": datetime.utcnow().isoformat()
    }


@app.get("/api/v1/device/info", tags=["Info"])
async def service_info():
    """Service information and configuration."""
    return {
        "service": "device-service",
        "version": "1.0.0",
        "aws_integration": {
            "iot_core": bool(IOT_ENDPOINT),
            "sqs_events": bool(DEVICE_EVENTS_QUEUE)
        },
        "device_count": len(devices_db),
        "device_types": len(device_types_db)
    }


# =============================================================================
# Device Type Endpoints (Golden Paths / Templates)
# =============================================================================

@app.get("/api/v1/device/types", tags=["Device Types"])
async def list_device_types():
    """
    List available device types.
    
    Textbook Reference: Ch. 3 - Golden Paths
    Pre-defined device templates make it easy to add new devices.
    """
    return {"device_types": list(device_types_db.values())}


@app.get("/api/v1/device/types/{type_id}", tags=["Device Types"])
async def get_device_type(type_id: str):
    """Get a specific device type."""
    if type_id not in device_types_db:
        raise HTTPException(status_code=404, detail="Device type not found")
    return device_types_db[type_id]


# =============================================================================
# Device CRUD Endpoints
# =============================================================================

@app.get("/api/v1/device/devices", tags=["Devices"])
async def list_devices(
    room: Optional[str] = Query(None, description="Filter by room"),
    online: Optional[bool] = Query(None, description="Filter by online status")
):
    """List all registered devices with optional filters."""
    devices = list(devices_db.values())
    
    if room:
        devices = [d for d in devices if d.room == room]
    if online is not None:
        devices = [d for d in devices if d.online == online]
    
    return {"devices": devices, "total": len(devices)}


@app.post("/api/v1/device/devices", tags=["Devices"], status_code=201)
async def create_device(device_create: DeviceCreate):
    """
    Register a new device.
    
    This creates a device in our registry and prepares it for
    IoT Core shadow synchronization.
    """
    # Validate device type
    if device_create.device_type_id not in device_types_db:
        raise HTTPException(status_code=400, detail="Invalid device type")
    
    device_type = device_types_db[device_create.device_type_id]
    
    # Generate device ID
    device_id = f"device-{len(devices_db) + 1:04d}"
    
    # Create device with default state from type
    device = Device(
        id=device_id,
        name=device_create.name,
        device_type_id=device_create.device_type_id,
        tuya_device_id=device_create.tuya_device_id,
        room=device_create.room,
        state=device_type.default_state.copy(),
        online=False
    )
    
    devices_db[device_id] = device
    
    # Publish creation event
    await publish_device_event("device.created", device)
    
    logger.info(f"Created device: {device_id} ({device.name})")
    return device


@app.get("/api/v1/device/devices/{device_id}", tags=["Devices"])
async def get_device(device_id: str):
    """Get device details including current state."""
    if device_id not in devices_db:
        raise HTTPException(status_code=404, detail="Device not found")
    
    device = devices_db[device_id]
    
    # If device has Tuya ID, try to get live state from IoT Core
    if device.tuya_device_id and IOT_ENDPOINT:
        thing_name = f"tuya-{device.tuya_device_id}"
        shadow_state = await get_device_shadow(thing_name)
        if shadow_state:
            device.state = shadow_state
            device.online = True
            device.last_seen = datetime.utcnow()
    
    return device


@app.delete("/api/v1/device/devices/{device_id}", tags=["Devices"])
async def delete_device(device_id: str):
    """Remove a device from the registry."""
    if device_id not in devices_db:
        raise HTTPException(status_code=404, detail="Device not found")
    
    device = devices_db.pop(device_id)
    await publish_device_event("device.deleted", device)
    
    return {"message": f"Device {device_id} deleted"}


# =============================================================================
# Device State & Control Endpoints
# =============================================================================

@app.get("/api/v1/device/devices/{device_id}/state", tags=["Device State"])
async def get_device_state(device_id: str):
    """Get current device state from IoT Core shadow."""
    if device_id not in devices_db:
        raise HTTPException(status_code=404, detail="Device not found")
    
    device = devices_db[device_id]
    
    if device.tuya_device_id and IOT_ENDPOINT:
        thing_name = f"tuya-{device.tuya_device_id}"
        shadow_state = await get_device_shadow(thing_name)
        if shadow_state:
            return {"state": shadow_state, "source": "iot_core"}
    
    return {"state": device.state, "source": "local"}


@app.put("/api/v1/device/devices/{device_id}/state", tags=["Device State"])
async def update_device_state(device_id: str, update: DeviceStateUpdate):
    """
    Update device state.
    
    For Tuya devices, this updates the IoT Core shadow's desired state,
    which triggers the Lambda bridge to send commands to the physical device.
    """
    if device_id not in devices_db:
        raise HTTPException(status_code=404, detail="Device not found")
    
    device = devices_db[device_id]
    
    if device.tuya_device_id and IOT_ENDPOINT:
        # Update via IoT Core shadow
        thing_name = f"tuya-{device.tuya_device_id}"
        await update_device_shadow(thing_name, update.state)
        device.state.update(update.state)
    else:
        # Local update only
        device.state.update(update.state)
    
    await publish_device_event("device.state_changed", device, update.state)
    
    return {"device_id": device_id, "state": device.state}


@app.post("/api/v1/device/devices/{device_id}/command", tags=["Device Control"])
async def send_device_command(device_id: str, command: CommandRequest):
    """
    Send a command to a device.
    
    This is a convenience endpoint that translates commands to state updates.
    """
    if device_id not in devices_db:
        raise HTTPException(status_code=404, detail="Device not found")
    
    device = devices_db[device_id]
    
    # Build state update from command
    state_update = {command.command: command.value}
    
    if device.tuya_device_id and IOT_ENDPOINT:
        thing_name = f"tuya-{device.tuya_device_id}"
        await update_device_shadow(thing_name, state_update)
        device.state.update(state_update)
    else:
        device.state.update(state_update)
    
    await publish_device_event("device.command", device, {
        "command": command.command,
        "value": command.value
    })
    
    return {
        "device_id": device_id,
        "command": command.command,
        "value": command.value,
        "success": True
    }


# =============================================================================
# Convenience Endpoints for Demo
# =============================================================================

@app.post("/api/v1/device/devices/{device_id}/on", tags=["Quick Controls"])
async def turn_device_on(device_id: str):
    """Turn device on (convenience endpoint)."""
    return await send_device_command(
        device_id, 
        CommandRequest(command="switch_led", value=True)
    )


@app.post("/api/v1/device/devices/{device_id}/off", tags=["Quick Controls"])
async def turn_device_off(device_id: str):
    """Turn device off (convenience endpoint)."""
    return await send_device_command(
        device_id,
        CommandRequest(command="switch_led", value=False)
    )


@app.post("/api/v1/device/devices/{device_id}/brightness", tags=["Quick Controls"])
async def set_brightness(device_id: str, level: int = Query(..., ge=10, le=1000)):
    """Set device brightness (10-1000)."""
    return await send_device_command(
        device_id,
        CommandRequest(command="bright_value_v2", value=level)
    )


# =============================================================================
# Run with: uvicorn main:app --host 0.0.0.0 --port 8001 --reload
# =============================================================================

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8001)
