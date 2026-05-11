# API Guide

The SmartHome Hub Platform exposes four microservices behind a single API Gateway. Every endpoint is `application/json` over HTTPS.

## Base URL

```
https://<api-id>.execute-api.<region>.amazonaws.com/<env>
```

Look it up after deploy:

```bash
cd aws/terraform && terraform output -raw api_gateway_url
```

All paths below are relative to that base.

## Authentication

The user-service issues a stateless JWT on successful login. Two ways to authenticate subsequent requests:

| Header | Use case |
|---|---|
| `Authorization: Bearer <jwt>` | Interactive sessions, 24-hour TTL |
| `X-API-Key: shk_<token>` | Service-to-service, programmatic access |

Endpoints marked **🔒** below require one of these headers. Everything else is open.

A seeded demo user is always available for testing:

```
email:    john.doe@example.com
password: demo123
```

## Errors

Standard HTTP status codes. Body shape:

```json
{ "detail": "human-readable message" }
```

For Pydantic validation failures (422), `detail` is an array of field-level errors.

## Quick example

```bash
BASE="$(cd aws/terraform && terraform output -raw api_gateway_url)"

# Login
TOKEN=$(curl -s -X POST "$BASE/api/v1/user/login" \
  -H 'Content-Type: application/json' \
  -d '{"email":"john.doe@example.com","password":"demo123"}' \
  | jq -r .token)

# Use the token
curl -s "$BASE/api/v1/user/me" -H "Authorization: Bearer $TOKEN" | jq .
```

For interactive exploration, every service exposes Swagger UI at `<base>/api/v1/<service>/docs`.

---

## device-service

Devices, device templates, and state control. State changes propagate to the physical device via the Tuya bridge.

### Device types (read-only templates)

| Method | Path | Description |
|---|---|---|
| GET | `/api/v1/device/types` | List available templates |
| GET | `/api/v1/device/types/{type_id}` | Get one template |

### Devices

| Method | Path | Description |
|---|---|---|
| GET | `/api/v1/device/devices` | List devices. Filters: `?room=X&online=true|false` |
| POST | `/api/v1/device/devices` | Create or upsert a device |
| GET | `/api/v1/device/devices/{id}` | Get one device + live state |
| DELETE | `/api/v1/device/devices/{id}` | Remove a device |

**Create body:**
```json
{
  "name": "Living Room Bulb",
  "device_type_id": "tuya-smart-bulb",
  "room": "living",
  "tuya_device_id": "bf02a9d4e1a2cf7d8be0kz"
}
```

`room` and `tuya_device_id` are optional. If `tuya_device_id` matches an existing device, the call upserts (returns the existing row with updated `name`/`room`).

### Device state

| Method | Path | Description |
|---|---|---|
| GET | `/api/v1/device/devices/{id}/state` | Current state (live from IoT shadow if `tuya_device_id` is set) |
| PUT | `/api/v1/device/devices/{id}/state` | Set desired state; merges into existing |

**State body:**
```json
{ "state": { "switch_led": true, "bright_value_v2": 800 } }
```

### Convenience controls

Convenience endpoints that wrap state updates with the right command codes:

| Method | Path | Description |
|---|---|---|
| POST | `/api/v1/device/devices/{id}/on` | Turn on |
| POST | `/api/v1/device/devices/{id}/off` | Turn off |
| POST | `/api/v1/device/devices/{id}/brightness?level=N` | Set brightness (`N` between 10 and 1000) |
| POST | `/api/v1/device/devices/{id}/command` | Send a raw command |

**Raw command body:**
```json
{ "command": "colour_data_v2", "value": { "h": 120, "s": 255, "v": 1000 } }
```

---

## automation-service

Pre-built automation templates ("Golden Paths") and user-created rules.

### Templates (read-only)

| Method | Path | Description |
|---|---|---|
| GET | `/api/v1/automation/templates` | List templates. Filter: `?category=lighting` |
| GET | `/api/v1/automation/templates/{id}` | Get one template |
| POST | `/api/v1/automation/templates/{id}/apply` | Create a rule from a template. Optional `?name=My+Rule` |

Seeded templates: `sunset-lights`, `motion-lights`, `away-mode`, `energy-saver`.

### Rules

| Method | Path | Description |
|---|---|---|
| GET | `/api/v1/automation/rules` | List rules. Filter: `?enabled=true|false` |
| POST | `/api/v1/automation/rules` | Create a rule from scratch |
| GET | `/api/v1/automation/rules/{id}` | Get one rule |
| DELETE | `/api/v1/automation/rules/{id}` | Remove a rule |
| POST | `/api/v1/automation/rules/{id}/enable` | Enable |
| POST | `/api/v1/automation/rules/{id}/disable` | Disable |
| POST | `/api/v1/automation/rules/{id}/trigger` | Fire manually (async) |

**Rule create body:**
```json
{
  "name": "Evening dim",
  "trigger_type": "schedule",
  "trigger_config": { "time": "20:00" },
  "actions": [
    { "type": "set_state", "target": "all_lights", "state": { "bright_value_v2": 300 } }
  ]
}
```

`trigger_type` is one of `device_state`, `schedule`, `manual`.

### History

| Method | Path | Description |
|---|---|---|
| GET | `/api/v1/automation/history` | Recent rule executions. `?limit=N` (default 20) |

---

## user-service

Authentication, profile, API key management.

### Auth (no auth required to call)

| Method | Path | Description |
|---|---|---|
| POST | `/api/v1/user/register` | Register a new user |
| POST | `/api/v1/user/login` | Authenticate, returns JWT |

**Register body:**
```json
{ "email": "alice@example.com", "name": "Alice", "password": "..." }
```

**Login body:**
```json
{ "email": "alice@example.com", "password": "..." }
```

**Login response:**
```json
{
  "token": "eyJ...",
  "user": { "id": "user-...", "email": "...", "name": "...", "role": "user" },
  "expires_at": "2026-05-12T..."
}
```

### Profile 🔒

| Method | Path | Description |
|---|---|---|
| GET | `/api/v1/user/me` | Current user profile |
| PUT | `/api/v1/user/me` | Update name and/or preferences |
| POST | `/api/v1/user/logout` | Client should discard the token (server is stateless) |

**Update body:**
```json
{ "name": "Alice Updated", "preferences": { "theme": "dark" } }
```

Both fields optional.

### Preferences 🔒

| Method | Path | Description |
|---|---|---|
| GET | `/api/v1/user/preferences` | Read preferences |
| PUT | `/api/v1/user/preferences` | Merge into existing preferences (raw dict body) |

### API keys 🔒

| Method | Path | Description |
|---|---|---|
| GET | `/api/v1/user/api-keys` | List your keys (without the secret) |
| POST | `/api/v1/user/api-keys` | Create a key — returned **once** |
| DELETE | `/api/v1/user/api-keys/{id}` | Revoke a key |

**Create body:**
```json
{ "name": "ci-key", "scopes": ["read"], "expires_in_days": 90 }
```

`scopes` and `expires_in_days` optional. Response includes the full `key` field; save it, it's never shown again.

---

## analytics-service

SLOs, developer-experience metrics, platform maturity, device telemetry.

### SLOs

| Method | Path | Description |
|---|---|---|
| GET | `/api/v1/analytics/slos` | List SLO definitions |
| GET | `/api/v1/analytics/slos/status` | Current status of each SLO |
| GET | `/api/v1/analytics/slos/{id}` | Get one SLO |

### DevEx metrics

| Method | Path | Description |
|---|---|---|
| GET | `/api/v1/analytics/devex` | Snapshot of headline DevEx metrics |
| POST | `/api/v1/analytics/devex/track` | Record a metric. Query params: `metric_name`, `value`, optional `category` |
| GET | `/api/v1/analytics/devex/recent` | Recent tracked metrics. `?limit=N&category=X` |

### Platform maturity

| Method | Path | Description |
|---|---|---|
| GET | `/api/v1/analytics/maturity` | Maturity assessment by dimension |

### Device telemetry

| Method | Path | Description |
|---|---|---|
| GET | `/api/v1/analytics/devices/{id}/metrics` | Time-series data. `?metric=X&hours=N` |
| GET | `/api/v1/analytics/devices/summary` | Aggregate device stats |
| GET | `/api/v1/analytics/usage` | Platform usage stats |

---

## Health & service info

Every service exposes:

| Method | Path | Description |
|---|---|---|
| GET | `/api/v1/<service>/info` | Version, config flags, instance hostname, basic counts |

Useful for verifying the load balancer is distributing requests — `info` returns the hostname of whichever container served the call.

The bare `/health` endpoints are also live on each service (used by the load balancer's health checks) and return `{"status":"healthy","service":"<name>"}`.
