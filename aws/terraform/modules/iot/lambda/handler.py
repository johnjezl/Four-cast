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
    
    def _sign(self, payload: str) -> str:
        """Generate HMAC-SHA256 signature."""
        return hmac.new(
            self.client_secret.encode('utf-8'),
            payload.encode('utf-8'),
            hashlib.sha256
        ).hexdigest().upper()
    
    def _get_token(self) -> str:
        """Get or refresh access token."""
        if self.token and time.time() < self.token_expiry:
            return self.token
        
        t = str(int(time.time() * 1000))
        sign_str = self.client_id + t
        sign = self._sign(sign_str)
        
        headers = {
            'client_id': self.client_id,
            't': t,
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
        
        sign_str = self.client_id + token + t
        sign = self._sign(sign_str)
        
        headers = {
            'client_id': self.client_id,
            'access_token': token,
            't': t,
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
        result = self._request('GET', f'/v1.0/devices/{device_id}/status')
        if result.get('success'):
            return result.get('result', [])
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
        result = self._request('POST', f'/v1.0/devices/{device_id}/commands', {
            'commands': commands
        })
        return result


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


# =============================================================================
# Lambda Handlers
# =============================================================================

def poll_tuya_devices(event, context):
    """
    Poll Tuya Cloud for device states and update IoT Core shadows.
    
    Triggered by EventBridge on a schedule (every 1 minute).
    
    Environment Variables:
        TUYA_DEVICE_IDS: Comma-separated list of device IDs
        SECRET_NAME: Secrets Manager secret with Tuya credentials
    """
    logger.info("Starting Tuya device poll")
    
    # Get device IDs from environment
    device_ids_str = os.environ.get('TUYA_DEVICE_IDS', '')
    device_ids = [d.strip() for d in device_ids_str.split(',') if d.strip()]
    
    if not device_ids:
        logger.warning("No device IDs configured")
        return {'statusCode': 200, 'body': 'No devices to poll'}
    
    # Initialize Tuya client
    creds = get_tuya_credentials()
    tuya = TuyaCloud(
        client_id=creds['client_id'],
        client_secret=creds['client_secret'],
        region=creds.get('region', 'us')
    )
    
    results = []
    
    for device_id in device_ids:
        try:
            # Get device status from Tuya
            status = tuya.get_device_status(device_id)
            
            if status:
                # Convert to shadow format
                shadow_state = tuya_status_to_shadow(status)
                
                # Update IoT Core shadow
                thing_name = f"tuya-{device_id}"
                update_iot_shadow(thing_name, shadow_state)
                
                results.append({
                    'device_id': device_id,
                    'status': 'success',
                    'state': shadow_state
                })
                logger.info(f"Synced device {device_id}: {shadow_state}")
            else:
                results.append({
                    'device_id': device_id,
                    'status': 'no_data'
                })
                logger.warning(f"No status data for device {device_id}")
                
        except Exception as e:
            logger.error(f"Error polling device {device_id}: {str(e)}")
            results.append({
                'device_id': device_id,
                'status': 'error',
                'error': str(e)
            })
    
    return {
        'statusCode': 200,
        'body': json.dumps({
            'message': 'Poll complete',
            'devices': results
        })
    }


def send_command_to_tuya(event, context):
    """
    Send command to Tuya device when IoT Core shadow desired state changes.
    
    Triggered by IoT Core Rule when shadow update contains desired state.
    
    Event Format (from IoT Rule):
        {
            "thingName": "tuya-<device_id>",
            "state": {
                "desired": {
                    "switch_led": true,
                    "bright_value_v2": 500
                }
            }
        }
    """
    logger.info(f"Received command event: {json.dumps(event)}")
    
    # Parse event
    thing_name = event.get('thingName', '')
    desired = event.get('state', {}).get('desired', {})
    
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
            # Clear desired state by updating shadow
            # (In production, you might want to verify the command succeeded first)
            iot_client.update_thing_shadow(
                thingName=thing_name,
                payload=json.dumps({
                    'state': {
                        'desired': None  # Clear desired state
                    }
                }).encode('utf-8')
            )
            
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
