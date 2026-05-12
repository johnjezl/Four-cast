"""
Tuya Bridge Service
===================
Bridges Tuya Cloud devices with the SmartHome platform. Replaces the two
former Lambdas (poll + command) with one long-running container.

Endpoints (all internal — not exposed via API Gateway):
- POST /command   accept a desired-state command and forward to Tuya
- POST /poll      manually trigger a poll cycle (also runs on a 60s loop)
- GET  /health    liveness

Outbound: POSTs reported state and pending-command retries to device-service
via X-Internal-Token-authenticated calls.
"""

import asyncio
import hashlib
import hmac
import json
import logging
import os
import time
import uuid
from contextlib import asynccontextmanager
from typing import Optional
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import boto3
import httpx
from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO").upper())
logger = logging.getLogger(__name__)

# =============================================================================
# Configuration
# =============================================================================

SECRET_NAME = os.getenv("SECRET_NAME", "")
DEVICE_SERVICE_URL = os.getenv("DEVICE_SERVICE_URL", "").rstrip("/")
INTERNAL_TOKEN = os.getenv("INTERNAL_TOKEN", "")
TUYA_DEVICE_IDS = os.getenv("TUYA_DEVICE_IDS", "").strip()
POLL_INTERVAL_SECONDS = int(os.getenv("POLL_INTERVAL_SECONDS", "60"))
AWS_REGION = os.getenv("AWS_REGION", "us-east-1")

secrets_client = boto3.client("secretsmanager", region_name=AWS_REGION)


# =============================================================================
# Tuya Cloud API Client
# =============================================================================
# Ported verbatim from the former Lambda handler. The HMAC signing algorithm
# and pagination quirks are documented inline because Tuya's docs are sparse.

class TuyaCloud:
    REGIONS = {
        "us": "https://openapi.tuyaus.com",
        "eu": "https://openapi.tuyaeu.com",
        "cn": "https://openapi.tuyacn.com",
        "in": "https://openapi.tuyain.com",
    }

    def __init__(self, client_id: str, client_secret: str, region: str = "us"):
        self.client_id = client_id
        self.client_secret = client_secret
        self.base_url = self.REGIONS.get(region, self.REGIONS["us"])
        self.token: Optional[str] = None
        self.token_expiry: float = 0

    def _sign(self, str_to_sign: str) -> str:
        return hmac.new(
            self.client_secret.encode("utf-8"),
            str_to_sign.encode("utf-8"),
            hashlib.sha256,
        ).hexdigest().upper()

    def _build_sign_str(self, method: str, path: str, t: str, nonce: str,
                        access_token: str = "", body: bytes = b"") -> str:
        body_hash = hashlib.sha256(body).hexdigest()
        string_to_sign = method + "\n" + body_hash + "\n\n" + path
        return self.client_id + access_token + t + nonce + string_to_sign

    def _get_token(self) -> str:
        if self.token and time.time() < self.token_expiry:
            return self.token

        t = str(int(time.time() * 1000))
        nonce = str(uuid.uuid4())
        sign = self._sign(self._build_sign_str("GET", "/v1.0/token?grant_type=1", t, nonce))

        headers = {
            "client_id": self.client_id,
            "t": t,
            "nonce": nonce,
            "sign": sign,
            "sign_method": "HMAC-SHA256",
        }
        url = f"{self.base_url}/v1.0/token?grant_type=1"
        request = Request(url, headers=headers, method="GET")
        try:
            with urlopen(request, timeout=10) as response:
                data = json.loads(response.read().decode("utf-8"))
        except HTTPError as e:
            logger.error(f"Token request failed: {e.code} {e.reason}")
            raise

        if not data.get("success"):
            raise RuntimeError(f"Failed to get token: {data}")

        self.token = data["result"]["access_token"]
        self.token_expiry = time.time() + data["result"]["expire_time"] - 60
        return self.token

    def _request(self, method: str, path: str, body: dict = None) -> dict:
        token = self._get_token()
        t = str(int(time.time() * 1000))
        nonce = str(uuid.uuid4())
        body_bytes = json.dumps(body).encode("utf-8") if body else b""
        sign = self._sign(self._build_sign_str(method, path, t, nonce, token, body_bytes))

        headers = {
            "client_id": self.client_id,
            "access_token": token,
            "t": t,
            "nonce": nonce,
            "sign": sign,
            "sign_method": "HMAC-SHA256",
        }
        url = f"{self.base_url}{path}"

        if method == "GET":
            request = Request(url, headers=headers, method="GET")
        else:
            headers["Content-Type"] = "application/json"
            data = json.dumps(body).encode("utf-8") if body else None
            request = Request(url, headers=headers, data=data, method=method)

        try:
            with urlopen(request, timeout=10) as response:
                return json.loads(response.read().decode("utf-8"))
        except HTTPError as e:
            logger.error(f"API request failed: {e.code} {e.reason}")
            raise

    def get_device_status(self, device_id: str) -> list:
        result = self._request("GET", f"/v2.0/cloud/thing/{device_id}/shadow/properties")
        if result.get("success"):
            return result.get("result", {}).get("properties", [])
        logger.error(f"Failed to get device status: {result}")
        return []

    def send_commands(self, device_id: str, commands: list) -> dict:
        return self._request(
            "POST",
            f"/v1.0/iot-03/devices/{device_id}/commands",
            {"commands": commands},
        )

    def list_spaces(self, page_size: int = 50) -> list:
        """Query params must be alphabetical — v2.0 endpoints reject
        out-of-order params with code 1004 'sign invalid'."""
        space_ids = []
        page_no = 1
        while True:
            path = f"/v2.0/cloud/space/child?page_no={page_no}&page_size={page_size}"
            result = self._request("GET", path)
            if not result.get("success"):
                logger.error(f"Failed to list spaces: {result}")
                break
            result_dict = result.get("result") or {}
            page = (result_dict.get("data")
                    or result_dict.get("list")
                    or result_dict.get("data_list")
                    or [])
            if not page:
                break
            for item in page:
                if isinstance(item, (int, str)):
                    space_ids.append(str(item))
                elif isinstance(item, dict):
                    sid = item.get("space_id") or item.get("id")
                    if sid:
                        space_ids.append(str(sid))
            if len(page) < page_size:
                break
            page_no += 1
        return space_ids

    def list_devices(self, space_ids: list = None, page_size: int = 10) -> list:
        """page_size capped at 10 by Tuya — larger values return 40000904
        'param size too much'."""
        if not space_ids:
            space_ids = self.list_spaces()
            logger.info(f"Discovered {len(space_ids)} Tuya space(s) to poll")
        if not space_ids:
            return []
        devices = []
        for space_id in space_ids:
            page_no = 1
            while True:
                path = (f"/v2.0/cloud/thing/space/device"
                        f"?page_no={page_no}&page_size={page_size}&space_ids={space_id}")
                result = self._request("GET", path)
                if not result.get("success"):
                    logger.error(f"Failed to list devices in space {space_id}: {result}")
                    break
                page = result.get("result", [])
                if isinstance(page, dict):
                    page = page.get("list", []) or page.get("data_list", [])
                if not page:
                    break
                devices.extend(page)
                if len(page) < page_size:
                    break
                page_no += 1
        return devices


# =============================================================================
# Tuya category → device_type_id mapping (carryover from Lambda)
# =============================================================================

_CATEGORY_TO_TYPE = {
    "dj": "tuya-smart-bulb",
    "dd": "tuya-smart-bulb",
    "xdd": "tuya-smart-bulb",
    "kg": "tuya-smart-plug",
    "cz": "tuya-smart-plug",
    "pc": "tuya-smart-plug",
}

_COMMAND_MAPPING = {
    "switch_led": "switch_led",
    "power": "switch_led",
    "bright_value_v2": "bright_value_v2",
    "brightness": "bright_value_v2",
    "colour_data_v2": "colour_data_v2",
    "color": "colour_data_v2",
    "temp_value_v2": "temp_value_v2",
    "work_mode": "work_mode",
}


def infer_device_type(tuya_category: str) -> str:
    return _CATEGORY_TO_TYPE.get((tuya_category or "").lower(), "tuya-smart-bulb")


def tuya_status_to_reported(status: list) -> dict:
    reported = {item.get("code"): item.get("value") for item in status if item.get("code")}
    reported["last_sync"] = int(time.time())
    return reported


# =============================================================================
# Credentials + Tuya client lifecycle
# =============================================================================

_tuya_singleton: Optional[TuyaCloud] = None


def get_tuya_credentials() -> dict:
    if not SECRET_NAME:
        raise RuntimeError("SECRET_NAME environment variable not set")
    response = secrets_client.get_secret_value(SecretId=SECRET_NAME)
    return json.loads(response["SecretString"])


def get_tuya_client() -> TuyaCloud:
    global _tuya_singleton
    if _tuya_singleton is None:
        creds = get_tuya_credentials()
        _tuya_singleton = TuyaCloud(
            client_id=creds["client_id"],
            client_secret=creds["client_secret"],
            region=creds.get("region", "us"),
        )
    return _tuya_singleton


# =============================================================================
# device-service HTTP client
# =============================================================================

http_client: Optional[httpx.AsyncClient] = None


def _internal_headers() -> dict:
    return {"X-Internal-Token": INTERNAL_TOKEN} if INTERNAL_TOKEN else {}


async def register_device(name: str, tuya_device_id: str, device_type_id: str) -> None:
    if not DEVICE_SERVICE_URL:
        return
    try:
        await http_client.post(
            f"{DEVICE_SERVICE_URL}/api/v1/device/devices",
            json={"name": name or f"Tuya {tuya_device_id[:8]}",
                  "device_type_id": device_type_id,
                  "tuya_device_id": tuya_device_id},
            timeout=10.0,
        )
    except Exception as e:
        logger.warning(f"register_device failed for {tuya_device_id}: {e}")


async def post_reported(tuya_device_id: str, reported: dict) -> None:
    if not DEVICE_SERVICE_URL:
        return
    try:
        await http_client.post(
            f"{DEVICE_SERVICE_URL}/api/v1/device/internal/reported",
            json={"tuya_device_id": tuya_device_id, "reported": reported},
            headers=_internal_headers(),
            timeout=10.0,
        )
    except Exception as e:
        logger.warning(f"post_reported failed for {tuya_device_id}: {e}")


async def fetch_pending() -> list:
    """Claim a batch of devices with stuck desired state for retry. The
    endpoint mutates retry_count/last_attempted server-side, so this is
    POST — repeated calls within the backoff window return nothing."""
    if not DEVICE_SERVICE_URL:
        return []
    try:
        r = await http_client.post(
            f"{DEVICE_SERVICE_URL}/api/v1/device/internal/pending",
            headers=_internal_headers(),
            timeout=10.0,
        )
        r.raise_for_status()
        return r.json().get("pending", [])
    except Exception as e:
        logger.warning(f"fetch_pending failed: {e}")
        return []


# =============================================================================
# Command + poll logic
# =============================================================================

def desired_to_commands(desired: dict) -> list:
    commands = []
    for key, value in desired.items():
        code = _COMMAND_MAPPING.get(key, key)
        commands.append({"code": code, "value": value})
    return commands


async def send_command(tuya_device_id: str, desired: dict) -> dict:
    """Send commands to Tuya, then optimistically report mapped codes back
    to device-service so the delta clears immediately."""
    commands = desired_to_commands(desired)
    if not commands:
        return {"status": "noop"}

    tuya = get_tuya_client()
    result = await asyncio.to_thread(tuya.send_commands, tuya_device_id, commands)
    logger.info(f"Sent commands to {tuya_device_id}: {commands} -> {result}")

    if result.get("success"):
        reported = {cmd["code"]: cmd["value"] for cmd in commands}
        await post_reported(tuya_device_id, reported)
        return {"status": "ok", "result": result}
    return {"status": "tuya_error", "result": result}


async def poll_once() -> dict:
    """Discover devices, register them, and report current state for each."""
    tuya = get_tuya_client()

    try:
        discovered = await asyncio.to_thread(tuya.list_devices)
    except Exception as e:
        logger.error(f"list_devices failed: {e}")
        return {"status": "error", "error": str(e)}

    logger.info(f"Discovered {len(discovered)} device(s) from Tuya")

    if TUYA_DEVICE_IDS:
        allowlist = {d.strip() for d in TUYA_DEVICE_IDS.split(",") if d.strip()}
        discovered = [d for d in discovered if (d.get("id") or d.get("device_id")) in allowlist]

    results = []
    for device in discovered:
        device_id = device.get("id") or device.get("device_id")
        if not device_id:
            continue
        device_type_id = infer_device_type(device.get("category"))
        name = device.get("name") or device.get("customName") or device.get("product_name", "")
        await register_device(name, device_id, device_type_id)
        try:
            status = await asyncio.to_thread(tuya.get_device_status, device_id)
            if status:
                reported = tuya_status_to_reported(status)
                await post_reported(device_id, reported)
                results.append({"device_id": device_id, "status": "ok"})
            else:
                results.append({"device_id": device_id, "status": "no_data"})
        except Exception as e:
            logger.error(f"Error polling {device_id}: {e}")
            results.append({"device_id": device_id, "status": "error", "error": str(e)})

    # Re-issue any pending desired-state commands that may have been dropped
    pending = await fetch_pending()
    for item in pending:
        tuya_device_id = item.get("tuya_device_id")
        desired = item.get("desired") or {}
        if not tuya_device_id or not desired:
            continue
        try:
            await send_command(tuya_device_id, desired)
        except Exception as e:
            logger.warning(f"retry send_command failed for {tuya_device_id}: {e}")

    return {"status": "ok", "devices": results, "retried_pending": len(pending)}


async def poll_loop():
    while True:
        try:
            await poll_once()
        except Exception as e:
            logger.error(f"poll_once crashed: {e}")
        await asyncio.sleep(POLL_INTERVAL_SECONDS)


# =============================================================================
# FastAPI app
# =============================================================================

@asynccontextmanager
async def lifespan(app: FastAPI):
    global http_client
    http_client = httpx.AsyncClient()
    logger.info(f"Tuya bridge starting; poll interval = {POLL_INTERVAL_SECONDS}s")
    task = asyncio.create_task(poll_loop())
    try:
        yield
    finally:
        task.cancel()
        await http_client.aclose()


app = FastAPI(title="Tuya Bridge", version="1.0.0", lifespan=lifespan)


class CommandRequest(BaseModel):
    tuya_device_id: str
    desired: dict


def require_internal_token(x_internal_token: Optional[str] = Header(None)):
    if not INTERNAL_TOKEN:
        return  # unconfigured — allow (dev mode)
    if x_internal_token != INTERNAL_TOKEN:
        raise HTTPException(status_code=401, detail="invalid internal token")


@app.get("/health")
async def health():
    return {"status": "healthy", "service": "tuya-bridge"}


@app.post("/api/v1/tuya-bridge/command")
async def command(req: CommandRequest, _: None = Depends(require_internal_token)):
    return await send_command(req.tuya_device_id, req.desired)


@app.post("/api/v1/tuya-bridge/poll")
async def poll(_: None = Depends(require_internal_token)):
    return await poll_once()


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8005)
