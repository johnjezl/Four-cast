"""
Tuya Bridge Lambda Functions
============================
Bridges Tuya Cloud devices with AWS IoT Core.

Functions:
- poll_tuya_devices: Polls Tuya Cloud and updates IoT Core shadows
- send_command_to_tuya: Sends commands from IoT Core to Tuya devices

Textbook Reference: Ch. 3 - Using managed services (IoT Core) with
custom integration code (Lambda) for non-standard devices.
"""

import json
import os
import hmac
import hashlib
import time
import uuid
import logging
from typing import Optional
from urllib.request import Request, urlopen
from urllib.error import HTTPError

import boto3

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# AWS clients
secrets_client = boto3.client('secretsmanager')
iot_client = boto3.client('iot-data')


# =============================================================================
# Tuya Cloud API Client
# =============================================================================

class TuyaCloud:
    """Client for Tuya Cloud API with automatic token management."""
    
    REGIONS = {
        'us': 'https://openapi.tuyaus.com',
        'eu': 'https://openapi.tuyaeu.com',
        'cn': 'https://openapi.tuyacn.com',
        'in': 'https://openapi.tuyain.com',
    }
    
    def __init__(self, client_id: str, client_secret: str, region: str = 'us'):
        self.client_id = client_id
        self.client_secret = client_secret
        self.base_url = self.REGIONS.get(region, self.REGIONS['us'])
        self.token: Optional[str] = None
        self.token_expiry: float = 0
    
    def _sign(self, str_to_sign: str) -> str:
        """Generate HMAC-SHA256 signature."""
        return hmac.new(
            self.client_secret.encode('utf-8'),
            str_to_sign.encode('utf-8'),
            hashlib.sha256
        ).hexdigest().upper()

    def _build_sign_str(self, method: str, path: str, t: str, nonce: str,
                        access_token: str = '', body: bytes = b'') -> str:
        """Build the string to sign per Tuya's post-2021 algorithm."""
        body_hash = hashlib.sha256(body).hexdigest()
        string_to_sign = method + '\n' + body_hash + '\n\n' + path
        return self.client_id + access_token + t + nonce + string_to_sign

    def _get_token(self) -> str:
        """Get or refresh access token."""
        if self.token and time.time() < self.token_expiry:
            return self.token

        t = str(int(time.time() * 1000))
        nonce = str(uuid.uuid4())
        sign = self._sign(self._build_sign_str('GET', '/v1.0/token?grant_type=1', t, nonce))

        headers = {
            'client_id': self.client_id,
            't': t,
            'nonce': nonce,
            'sign': sign,
            'sign_method': 'HMAC-SHA256',
        }
        
        url = f"{self.base_url}/v1.0/token?grant_type=1"
        request = Request(url, headers=headers, method='GET')
        
        try:
            with urlopen(request, timeout=10) as response:
                data = json.loads(response.read().decode('utf-8'))
        except HTTPError as e:
            logger.error(f"Token request failed: {e.code} {e.reason}")
            raise
        
        if data.get('success'):
            self.token = data['result']['access_token']
            # Refresh 60 seconds before expiry
            self.token_expiry = time.time() + data['result']['expire_time'] - 60
            return self.token
        else:
            raise Exception(f"Failed to get token: {data}")
    
    def _request(self, method: str, path: str, body: dict = None) -> dict:
        """Make authenticated API request."""
        token = self._get_token()
        t = str(int(time.time() * 1000))
        nonce = str(uuid.uuid4())
        body_bytes = json.dumps(body).encode('utf-8') if body else b''
        sign = self._sign(self._build_sign_str(method, path, t, nonce, token, body_bytes))

        headers = {
            'client_id': self.client_id,
            'access_token': token,
            't': t,
            'nonce': nonce,
            'sign': sign,
            'sign_method': 'HMAC-SHA256',
        }
        
        url = f"{self.base_url}{path}"
        
        if method == 'GET':
            request = Request(url, headers=headers, method='GET')
        else:
            headers['Content-Type'] = 'application/json'
            data = json.dumps(body).encode('utf-8') if body else None
            request = Request(url, headers=headers, data=data, method=method)
        
        try:
            with urlopen(request, timeout=10) as response:
                return json.loads(response.read().decode('utf-8'))
        except HTTPError as e:
            logger.error(f"API request failed: {e.code} {e.reason}")
            raise
    
    def get_device_status(self, device_id: str) -> list:
        """Get current status of a device."""
        result = self._request('GET', f'/v2.0/cloud/thing/{device_id}/shadow/properties')
        if result.get('success'):
            return result.get('result', {}).get('properties', [])
        else:
            logger.error(f"Failed to get device status: {result}")
            return []
    
    def get_device_info(self, device_id: str) -> dict:
        """Get device information."""
        result = self._request('GET', f'/v1.0/devices/{device_id}')
        if result.get('success'):
            return result.get('result', {})
        return {}
    
    def send_commands(self, device_id: str, commands: list) -> dict:
        """Send commands to a device."""
        return self._request('POST', f'/v1.0/iot-03/devices/{device_id}/commands', {
            'commands': commands
        })

    def list_spaces(self, page_size: int = 50) -> list:
        """List space IDs accessible to the cloud project. Paginated.
        Query params are sorted alphabetically — v2.0 endpoints reject
        out-of-order params with code 1004 "sign invalid".
        Returns a list of space ID strings."""
        space_ids = []
        page_no = 1
        while True:
            path = f'/v2.0/cloud/space/child?page_no={page_no}&page_size={page_size}'
            result = self._request('GET', path)
            if not result.get('success'):
                logger.error(f"Failed to list spaces: {result}")
                break
            result_dict = result.get('result') or {}
            # Tuya returns the IDs under `data` for this endpoint; tolerate the
            # other shapes too in case the response format varies.
            page = (result_dict.get('data')
                    or result_dict.get('list')
                    or result_dict.get('data_list')
                    or [])
            if not page:
                break
            for item in page:
                if isinstance(item, (int, str)):
                    space_ids.append(str(item))
                elif isinstance(item, dict):
                    sid = item.get('space_id') or item.get('id')
                    if sid:
                        space_ids.append(str(sid))
            if len(page) < page_size:
                break
            page_no += 1
        return space_ids

    def list_devices(self, space_ids: list = None, page_size: int = 10) -> list:
        """List devices across Tuya spaces. If no space_ids are given, all
        spaces accessible to the project are discovered first.

        page_size is capped at 10 by Tuya — larger values return code
        40000904 'param size too much'."""
        if not space_ids:
            space_ids = self.list_spaces()
            logger.info(f"Discovered {len(space_ids)} Tuya space(s) to poll")
        if not space_ids:
            return []
        devices = []
        for space_id in space_ids:
            page_no = 1
            while True:
                # Query params alphabetical: page_no, page_size, space_ids.
                path = (f'/v2.0/cloud/thing/space/device'
                        f'?page_no={page_no}&page_size={page_size}&space_ids={space_id}')
                result = self._request('GET', path)
                if not result.get('success'):
                    logger.error(f"Failed to list devices in space {space_id}: {result}")
                    break
                page = result.get('result', [])
                if isinstance(page, dict):
                    page = page.get('list', []) or page.get('data_list', [])
                if not page:
                    break
                devices.extend(page)
                if len(page) < page_size:
                    break
                page_no += 1
        return devices


# =============================================================================
# Helper Functions
# =============================================================================

def get_tuya_credentials() -> dict:
    """Retrieve Tuya credentials from Secrets Manager."""
    secret_name = os.environ.get('SECRET_NAME')
    if not secret_name:
        raise ValueError("SECRET_NAME environment variable not set")
    
    response = secrets_client.get_secret_value(SecretId=secret_name)
    return json.loads(response['SecretString'])


def update_iot_shadow(thing_name: str, reported_state: dict) -> None:
    """Update IoT Core device shadow with reported state."""
    shadow_payload = {
        'state': {
            'reported': reported_state
        }
    }
    
    iot_client.update_thing_shadow(
        thingName=thing_name,
        payload=json.dumps(shadow_payload).encode('utf-8')
    )
    logger.info(f"Updated shadow for {thing_name}")


def tuya_status_to_shadow(status: list) -> dict:
    """Convert Tuya status array to shadow format."""
    shadow = {}
    for item in status:
        code = item.get('code')
        value = item.get('value')
        shadow[code] = value

    shadow['last_sync'] = int(time.time())
    return shadow


# Map Tuya device categories to our seeded device_type_ids.
# Tuya category reference: dj=light, kg=switch, cz=socket/plug.
_CATEGORY_TO_TYPE = {
    'dj': 'tuya-smart-bulb',
    'dd': 'tuya-smart-bulb',
    'xdd': 'tuya-smart-bulb',
    'kg': 'tuya-smart-plug',
    'cz': 'tuya-smart-plug',
    'pc': 'tuya-smart-plug',
}


def infer_device_type(tuya_category: str) -> str:
    return _CATEGORY_TO_TYPE.get((tuya_category or '').lower(), 'tuya-smart-bulb')


def register_with_device_service(name: str, tuya_device_id: str, device_type_id: str) -> bool:
    """POST to device-service. Idempotent — device-service upserts on tuya_device_id."""
    alb_url = os.environ.get('ALB_URL', '').rstrip('/')
    if not alb_url:
        logger.warning("ALB_URL not set; skipping device-service registration")
        return False

    payload = json.dumps({
        'name': name or f'Tuya {tuya_device_id[:8]}',
        'device_type_id': device_type_id,
        'tuya_device_id': tuya_device_id,
    }).encode('utf-8')

    request = Request(
        f'{alb_url}/api/v1/device/devices',
        data=payload,
        headers={'Content-Type': 'application/json'},
        method='POST',
    )
    try:
        with urlopen(request, timeout=10) as response:
            return response.status in (200, 201)
    except HTTPError as e:
        logger.warning(f"device-service register failed for {tuya_device_id}: {e.code} {e.reason}")
        return False
    except Exception as e:
        logger.warning(f"device-service register error for {tuya_device_id}: {e}")
        return False


# =============================================================================
# Lambda Handlers
# =============================================================================

def poll_tuya_devices(event, context):
    """
    Discover devices from Tuya, register them with device-service, then sync
    each device's current state into IoT Core shadows.

    Triggered by EventBridge on a 1-minute schedule.

    Environment Variables:
        SECRET_NAME      Secrets Manager secret with Tuya credentials (required)
        ALB_URL          Base URL of the device-service ALB (required for registration)
        TUYA_DEVICE_IDS  Optional comma-separated allowlist; if set, only these
                         IDs are polled. Useful for testing. When unset, all
                         devices discovered from Tuya are polled.
    """
    logger.info("Starting Tuya device poll")

    creds = get_tuya_credentials()
    tuya = TuyaCloud(
        client_id=creds['client_id'],
        client_secret=creds['client_secret'],
        region=creds.get('region', 'us'),
    )

    # Discover devices across all spaces visible to the cloud project
    try:
        discovered = tuya.list_devices()
    except Exception as e:
        logger.error(f"Failed to list devices from Tuya: {e}")
        return {'statusCode': 500, 'body': f'Tuya list_devices failed: {e}'}

    logger.info(f"Discovered {len(discovered)} device(s) from Tuya")

    # Optional allowlist for targeted testing
    allowlist_str = os.environ.get('TUYA_DEVICE_IDS', '').strip()
    if allowlist_str:
        allowlist = {d.strip() for d in allowlist_str.split(',') if d.strip()}
        discovered = [d for d in discovered if (d.get('id') or d.get('device_id')) in allowlist]
        logger.info(f"Filtered to {len(discovered)} device(s) via TUYA_DEVICE_IDS allowlist")

    results = []
    for device in discovered:
        # v2.0 may return either `id` or `device_id`; tolerate both.
        device_id = device.get('id') or device.get('device_id')
        if not device_id:
            continue

        device_type_id = infer_device_type(device.get('category'))
        device_name = device.get('name') or device.get('customName') or device.get('product_name', '')
        register_with_device_service(
            name=device_name,
            tuya_device_id=device_id,
            device_type_id=device_type_id,
        )

        try:
            status = tuya.get_device_status(device_id)
            if status:
                shadow_state = tuya_status_to_shadow(status)
                update_iot_shadow(f"tuya-{device_id}", shadow_state)
                results.append({'device_id': device_id, 'status': 'success', 'state': shadow_state})
                logger.info(f"Synced device {device_id}: {shadow_state}")
            else:
                results.append({'device_id': device_id, 'status': 'no_data'})
                logger.warning(f"No status data for device {device_id}")
        except Exception as e:
            logger.error(f"Error polling device {device_id}: {e}")
            results.append({'device_id': device_id, 'status': 'error', 'error': str(e)})

    return {
        'statusCode': 200,
        'body': json.dumps({'message': 'Poll complete', 'devices': results}),
    }


def send_command_to_tuya(event, context):
    """
    Send command to Tuya device when IoT Core shadow desired state changes.
    
    Triggered by IoT Core Rule when shadow update contains desired state.
    
    Event Format (from IoT Rule, projected from $aws/things/+/shadow/update/delta):
        {
            "thingName": "tuya-<device_id>",
            "desired": {
                "switch_led": true,
                "bright_value_v2": 500
            }
        }
    """
    logger.info(f"Received command event: {json.dumps(event)}")

    # Parse event
    thing_name = event.get('thingName', '')
    desired = event.get('desired', {})
    
    if not thing_name or not desired:
        logger.warning("Missing thingName or desired state")
        return {'statusCode': 400, 'body': 'Missing required fields'}
    
    # Extract Tuya device ID from thing name
    if thing_name.startswith('tuya-'):
        device_id = thing_name[5:]  # Remove 'tuya-' prefix
    else:
        device_id = thing_name
    
    # Initialize Tuya client
    creds = get_tuya_credentials()
    tuya = TuyaCloud(
        client_id=creds['client_id'],
        client_secret=creds['client_secret'],
        region=creds.get('region', 'us')
    )
    
    # Build commands from desired state
    commands = []
    
    # Map common properties to Tuya commands
    command_mapping = {
        'switch_led': 'switch_led',
        'power': 'switch_led',
        'bright_value_v2': 'bright_value_v2',
        'brightness': 'bright_value_v2',
        'colour_data_v2': 'colour_data_v2',
        'color': 'colour_data_v2',
        'temp_value_v2': 'temp_value_v2',
        'work_mode': 'work_mode',
    }
    
    for key, value in desired.items():
        tuya_code = command_mapping.get(key, key)
        commands.append({
            'code': tuya_code,
            'value': value
        })
    
    if not commands:
        logger.info("No commands to send")
        return {'statusCode': 200, 'body': 'No commands'}
    
    try:
        # Send commands to Tuya
        result = tuya.send_commands(device_id, commands)
        logger.info(f"Sent commands to {device_id}: {commands} -> {result}")

        if result.get('success'):
            # Mirror the accepted command into `reported` so the delta clears
            # immediately. Use the Tuya-coded keys (not the user-facing aliases)
            # so the next poller tick overwrites cleanly without leaving stale
            # duplicate-vocabulary keys in the shadow document.
            reported = {cmd['code']: cmd['value'] for cmd in commands}
            try:
                update_iot_shadow(thing_name, reported)
            except Exception as shadow_err:
                logger.warning(f"Tuya accepted command but shadow update failed: {shadow_err}")

            return {
                'statusCode': 200,
                'body': json.dumps({
                    'message': 'Commands sent',
                    'device_id': device_id,
                    'commands': commands,
                    'result': result
                })
            }
        else:
            return {
                'statusCode': 500,
                'body': json.dumps({
                    'error': 'Tuya API error',
                    'result': result
                })
            }
            
    except Exception as e:
        logger.error(f"Error sending commands: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(e)})
        }
