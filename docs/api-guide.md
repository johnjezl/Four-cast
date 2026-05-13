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

The platform speaks a canonical capability vocabulary. Vendor-specific datapoint codes (`switch_led`, `bright_value_v2`, etc.) only exist inside the appropriate adapter — `device-service` and your code should use the capability names below.

> **Breaking change (v3)**: the API previously accepted Tuya datapoint codes directly (`switch_led`, `bright_value_v2`, `colour_data_v2`), and `/brightness?level=` took 10–1000. Both now expect canonical names and 0–100 ranges. Any client outside `test_apis.sh` that issued raw Tuya codes needs updating.

| Capability | Type | Range | Description |
|---|---|---|---|
| `power` | bool | — | On/off |
| `brightness` | int | 0–100 | Percent of device maximum. **Note:** `0` clamps to ~1% on most hardware (vendor minimum). Use `power: false` to actually turn off. |
| `color` | object | `{ h: 0–360, s: 0–100, v: 0–100 }` | HSV |
| `color_temp` | int | 0–100 | 0 = warmest, 100 = coolest |
| `mode` | string | `white \| colour \| scene \| music` | Bulb operating mode |
| `temperature` | float | -40.0–180.0 (°F) | **Read-only.** Sensor reading; received via `/protocol/v1/telemetry`. Cannot be set via `/state` or `/command`. |
| `humidity` | float | 0.0–100.0 (%) | **Read-only.** Sensor reading; same path as `temperature`. |

Validation at the API edge:

- State keys not declared on the device type's `capabilities` are rejected with 400.
- Values are type-checked and range-checked against this table.
- For object capabilities (`color`), unknown sub-keys (e.g. `color.alpha`) are also rejected with 400.

Fetch the machine-readable version at:

```
GET /api/v1/device/capabilities
```

| Method | Path | Description |
|---|---|---|
| GET | `/api/v1/device/devices/{id}/state` | Current state (merged view of reported + desired) |
| PUT | `/api/v1/device/devices/{id}/state` | Set desired state; merges into existing |

**State body:**
```json
{ "state": { "power": true, "brightness": 80 } }
```

**Merge semantics on PUT.** Top-level keys shallow-replace: writing `{"state": {"power": false}}` leaves `brightness` untouched. Object capabilities (today just `color`) **deep-merge** their sub-keys — `{"state": {"color": {"h": 200}}}` changes the hue while preserving the existing `s` and `v`. Send all sub-keys explicitly if you want to replace the whole object.

**GET response shape:**
```json
{
  "state":    { "power": true, "brightness": 80 },
  "desired":  { "power": true },
  "reported": { "brightness": 80, "last_sync": 1715472000 },
  "version":  42,
  "source":   "postgres"
}
```

`state` is the user-facing flattened view (reported with desired overlaid). `desired` lists keys still pending convergence — these clear automatically as the bridge reports them back. `version` increments on every write and can be used for optimistic-concurrency checks if you need them.

### Convenience controls

| Method | Path | Description |
|---|---|---|
| POST | `/api/v1/device/devices/{id}/on` | Set `power: true` |
| POST | `/api/v1/device/devices/{id}/off` | Set `power: false` |
| POST | `/api/v1/device/devices/{id}/brightness?level=N` | Set `brightness: N` (`N` between 0 and 100) |
| POST | `/api/v1/device/devices/{id}/command` | Send a single-capability command |

**Command body:**
```json
{ "capability": "color", "value": { "h": 120, "s": 80, "v": 100 } }
```

### Device protocol v1 — telemetry (Shelly H&T and future direct WiFi devices)

For devices that don't go through a vendor cloud and instead push readings directly over HTTPS — currently the Shelly H&T Gen3 temperature/humidity sensor. The model is:

- **Each device gets a long-lived API key**, issued once at registration time and stored only as a bcrypt hash on the server.
- **The device authenticates** every request with `X-Device-Key: dvk_<token>`.
- **Sensor readings are pushed**, not polled — the device wakes on a schedule, posts to `/protocol/v1/telemetry`, and goes back to sleep.

#### Device keys

| Method | Path | Description |
|---|---|---|
| POST | `/api/v1/device/devices/{id}/keys` | Issue a new key for a device. Plaintext is returned **once** in the `key` field. |
| GET | `/api/v1/device/devices/{id}/keys` | List a device's keys (prefix, scopes, lifecycle timestamps — no plaintext). |
| DELETE | `/api/v1/device/devices/{id}/keys/{key_id}` | Revoke a key (soft-delete; preserves audit trail). |

**Issue body:**
```json
{ "scopes": ["write_telemetry"] }
```

`scopes` is optional and defaults to `["read_pending", "write_reported"]` (the polling-protocol scopes). For Shelly H&T and other telemetry-pushing sensors, pass `["write_telemetry"]` explicitly.

**Issue response:**
```json
{
  "id": "key-uuid",
  "device_id": "device-...",
  "key": "dvk_AbCd...",
  "key_prefix": "dvk_AbCd",
  "scopes": ["write_telemetry"],
  "created_at": "2026-05-12T20:30:00",
  "snippets": {
    "shelly_action": { "url": "...", "method": "POST", "headers": {...}, "body": {...} }
  }
}
```

`snippets` is populated based on `device_metadata.subtype`. For a device created with `device_metadata: {"subtype": "shelly_ht_gen3"}`, the response includes a copy-paste-ready Shelly Action JSON in `snippets.shelly_action`. Other device families (none yet) would add their own keys without changing the response schema.

> **Save the `key` value immediately.** It's only returned in this response — there's no way to retrieve it later. If you lose it, revoke the key and issue a new one.

#### Push telemetry (device → platform)

| Method | Path | Description |
|---|---|---|
| POST | `/api/v1/device/protocol/v1/telemetry` | Receive a batch of sensor readings. Auth: `X-Device-Key` with `write_telemetry` scope. |

**Body:**
```json
{
  "readings": { "temperature": 71.6, "humidity": 44.2 },
  "recorded_at": "2026-05-12T20:30:00Z"
}
```

`recorded_at` is optional. When supplied, the platform uses it for idempotent dedup of retried webhooks — sending the same `(device, capability, recorded_at)` tuple twice is a no-op.

**Responses:** `204 No Content` on success (whether one or more readings were accepted, or all were filtered as unknown/out-of-range). Validation is lenient — unknown capabilities and out-of-range values are logged and dropped, not rejected with 400, so Shelly firmware updates that add new fields don't flap the endpoint.

| Status | Reason |
|---|---|
| `204` | One or more readings accepted, or every reading filtered (still 204 — no client signal needed) |
| `400` | Body malformed JSON / fails the schema |
| `401` | `X-Device-Key` missing, malformed, unknown, or revoked |
| `403` | Key valid but lacks `write_telemetry` scope |

#### Read telemetry 🔒 (platform → user)

| Method | Path | Description |
|---|---|---|
| GET | `/api/v1/device/devices/{id}/telemetry` | Time-ordered, paginated readings for a device. |

Query parameters:

| Param | Default | Description |
|---|---|---|
| `since` | `now - 24h` | Lower bound on `received_at` (ISO8601) |
| `capability` | — | Optional filter to a single capability (`temperature` or `humidity`) |
| `limit` | `1000` (max `10000`) | Page size |
| `cursor` | — | Opaque pagination cursor returned by a prior page |

**Response:**
```json
{
  "device_id": "device-...",
  "readings": [
    { "capability": "temperature", "value": 71.6, "recorded_at": "...", "received_at": "..." },
    { "capability": "humidity", "value": 44.2, "recorded_at": null, "received_at": "..." }
  ],
  "next_cursor": "MjAyNi0wNS0xMlQyMDozMDowMHwxNDI"
}
```

Readings are returned **newest first**. `next_cursor` is `null` on the last page; pass it back as `?cursor=...` for the next page. `recorded_at` is `null` when the device didn't supply a timestamp on push.

#### Onboarding flow — Shelly H&T Gen3

1. Create the device with the H&T subtype:
   ```json
   POST /api/v1/device/devices
   { "name": "Living Room Sensor",
     "device_type_id": "sensor",
     "device_metadata": { "subtype": "shelly_ht_gen3" } }
   ```
2. Issue a write-telemetry key:
   ```bash
   curl -X POST "$BASE/api/v1/device/devices/$DEV/keys" \
     -H 'Content-Type: application/json' \
     -d '{ "scopes": ["write_telemetry"] }'
   ```
3. Copy `snippets.shelly_action` from the response into the Shelly device's web UI under **Settings → Actions** (or POST it to `http://<device-ip>/rpc/Webhook.Create`).
4. The device will fire the action on each wake-up; readings appear under `GET /devices/{id}/telemetry`.

> **Placeholder names** (`${temperature_F}`, `${humidity}`, `${ts}`) in the generated snippet are the design doc's sketch and may differ from the actual Shelly Gen3 RPC variable names. Verify against firmware before applying to a production device — the snippet's `_note` field carries the same warning.

#### Bus events

Each successful telemetry write produces one `device.telemetry` event on the platform's event bus (Pub/Sub on GCP, SQS on AWS). Payload:

```json
{
  "event": "device.telemetry",
  "device_id": "device-...",
  "device_type": "sensor",
  "readings": { "temperature": 71.6, "humidity": 44.2 },
  "recorded_at": "2026-05-12T20:30:00",
  "received_at": "2026-05-12T20:30:02"
}
```

`recorded_at` on the bus is always populated, falling back to `received_at` when the device didn't supply one. Consumers (analytics, automation) should switch on the `event_type` Pub/Sub attribute (`"device.telemetry"`).

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
    { "type": "set_state", "target": "all_lights", "state": { "brightness": 30 } }
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

SLOs, developer-experience metrics, platform maturity, device telemetry. Most aggregates derive from a Postgres `event_log` table populated by a background SQS consumer that ingests every `device.*` event the platform emits.

### SLOs

| Method | Path | Description |
|---|---|---|
| GET | `/api/v1/analytics/slos` | List SLO definitions |
| GET | `/api/v1/analytics/slos/status` | Current status of each SLO. Response includes `"mock": true` — current values are still static placeholders until real latency/availability tracking is wired up |
| GET | `/api/v1/analytics/slos/{id}` | Get one SLO |

### DevEx metrics

| Method | Path | Description |
|---|---|---|
| GET | `/api/v1/analytics/devex` | Snapshot of headline DevEx metrics. Each entry has `"source": "measured"` (averaged from `devex_metrics`) or `"source": "default"` (demo value) |
| POST | `/api/v1/analytics/devex/track` | Record a metric. Query params: `metric_name`, `value`, optional `category` |
| GET | `/api/v1/analytics/devex/recent` | Recent tracked metrics. `?limit=N&category=X` |

### Platform maturity

| Method | Path | Description |
|---|---|---|
| GET | `/api/v1/analytics/maturity` | Maturity assessment by dimension (static seed data) |

### Device telemetry

| Method | Path | Description |
|---|---|---|
| GET | `/api/v1/analytics/devices/{id}/metrics` | Events for a device. `?event_type=device.state_changed&hours=N` (1-168) |
| GET | `/api/v1/analytics/devices/summary` | Live device counts (via device-service) + command/automation counts today |
| GET | `/api/v1/analytics/usage` | Event volume and top event types over the last 24h / 7d |

---

## Health & service info

Every service exposes:

| Method | Path | Description |
|---|---|---|
| GET | `/api/v1/<service>/info` | Version, config flags, instance hostname, basic counts |

Useful for verifying the load balancer is distributing requests — `info` returns the hostname of whichever container served the call.

The bare `/health` endpoints are also live on each service (used by the load balancer's health checks) and return `{"status":"healthy","service":"<name>"}`.
