# Device Protocol — Direct-Integration Design

**Status**: transient design note. Not committed; will be revisited later. May be discarded.

## TL;DR

For devices that don't go through a vendor cloud (ESP32, Pi, custom hardware), the device itself plays the role of the bridge. The cleanest first version is HTTP polling: device calls a public protocol endpoint for pending commands, posts reported state back. Per-device API keys for auth. WebSocket push is a future v2 if latency becomes a real concern.

The platform already has all the necessary pieces. The new work is mostly about *promoting* internal endpoints to a documented public protocol and adding per-device authentication.

## Prerequisites met by current architecture

- Canonical capability vocabulary on the API and in the shadow envelope (PR #6).
- `{desired, reported, version, retry_count, last_attempted}` envelope already enforces convergence semantics.
- `/internal/reported` and `/internal/pending` already implement the exact server-side contract a device adapter needs.

## Architecture

```
                          ┌────────────────────────────────┐
                          │   device-service (Fargate)     │
                          │                                │
   tuya-bridge ─────────► │   /internal/pending  ◄── short │
   (INTERNAL_TOKEN auth)  │   /internal/reported  ── circuit, server-to-server
                          │                                │
   direct device  ──────► │   /protocol/v1/pending  ◄── public, per-device key
   (X-Device-Key auth)    │   /protocol/v1/reported ──     │
                          └────────────────────────────────┘
                                      │
                                      ▼
                              ┌──────────────┐
                              │  Postgres    │
                              │  devices     │
                              │  device_keys │
                              └──────────────┘
```

Two adapter surfaces, same underlying shadow model, different auth.

## Authentication

Each direct device gets a long-lived API key issued at registration time. Stored hashed in a new `device_keys` table; the plaintext is returned **once** at creation and the device firmware stores it.

```
device_keys
─────────────────────────────────
id             UUID PK
device_id      FK → devices.id
key_hash       text     (bcrypt of the issued key)
key_prefix     text     (first 8 chars, for display/lookup hints)
scopes         jsonb    (default: ["read_pending", "write_reported"])
created_at     timestamp
last_used_at   timestamp
revoked_at     timestamp NULLABLE
```

Management endpoints (admin only):

| Method | Path | Description |
|---|---|---|
| POST | `/api/v1/device/devices/{id}/keys` | Issue a new key. Response includes plaintext **once**. |
| GET  | `/api/v1/device/devices/{id}/keys` | List keys (prefix + last_used_at, no plaintext). |
| DELETE | `/api/v1/device/devices/{id}/keys/{key_id}` | Revoke a key. |

Authentication on protocol endpoints: device sends `X-Device-Key: <key>`, server looks up the matching `device_keys` row by hash, populates `device_id` from the FK, sets `last_used_at = now()`, rejects revoked.

## Pattern A: polling protocol (v1)

The device polls two endpoints on its own schedule. Server doesn't push.

### GET /api/v1/device/protocol/v1/pending

Returns the device's current desired state, if any keys are unresolved. Atomically bumps `retry_count` and `last_attempted` (same semantics as `/internal/pending`) so we get backoff and DLQ-style give-up for free.

**Request:**
```
GET /api/v1/device/protocol/v1/pending
X-Device-Key: <key>
```

**Response (200, work to do):**
```json
{
  "desired": { "power": true, "brightness": 80 },
  "version": 42,
  "retry_count": 1
}
```

**Response (204, nothing pending):** empty body. Device sleeps until next poll.

### POST /api/v1/device/protocol/v1/reported

Device pushes its current reported state. Matching desired keys are cleared (delta-clear). Identical body shape to `/internal/reported` minus the `tuya_device_id` field (the device is identified by the API key).

**Request:**
```json
POST /api/v1/device/protocol/v1/reported
X-Device-Key: <key>
Content-Type: application/json

{ "reported": { "power": true, "brightness": 80 } }
```

**Response:** `{ "status": "ok", "version": 43 }`

### Polling cadence

Suggested: every 5 seconds when idle, every 1 second after the device just did something (in case the user immediately changed their mind). Adaptive backoff keeps the request rate sane at scale. Server should tolerate any cadence — the rate-limiting is on the device's good behavior, not enforced server-side beyond what the standard API Gateway throttling already does.

## Pattern B: WebSocket push (future v2)

Only worth building if v1's poll latency turns out to be a real problem. Sketch:

```
WS /api/v1/device/protocol/v1/connect
  ↑ initial message: {"type":"auth","key":"<X-Device-Key>"}
  ← server: {"type":"hello","device_id":"...","version":42}

  ← server: {"type":"command","desired":{"power":true},"version":43}
  ↑ device: {"type":"reported","reported":{"power":true}}

  Keep-alive: ping every 30s, drop after 60s of silence.
```

Trade-offs vs polling:
- **+** sub-second command latency
- **+** lower request volume at scale
- **−** stateful connection per device; need sticky session or proxy that can route by `device_id`
- **−** ALB doesn't do WebSockets cleanly across multiple Fargate replicas without session affinity; might need API Gateway WebSocket support or a different LB
- **−** more complex device firmware (reconnect logic, ping/pong)

Defer until polling-based usage has real numbers showing where the bottleneck is.

## Example device firmware (Pattern A, pseudo-Python)

```python
import requests, time

API_BASE = "https://api.smarthome.example/api/v1/device/protocol/v1"
DEVICE_KEY = "dvk_..."  # from registration
HEADERS = {"X-Device-Key": DEVICE_KEY}

def apply_command(desired):
    """Translate canonical capabilities to local hardware actions."""
    if "power" in desired:
        gpio.write(POWER_PIN, desired["power"])
    if "brightness" in desired:
        pwm.set(LED_PIN, int(desired["brightness"]) * 255 // 100)
    # ... etc

def current_state():
    return {
        "power": gpio.read(POWER_PIN),
        "brightness": pwm.get_pct(LED_PIN),
    }

while True:
    r = requests.get(f"{API_BASE}/pending", headers=HEADERS, timeout=10)
    if r.status_code == 200 and r.json().get("desired"):
        apply_command(r.json()["desired"])
        # Report immediately after applying — don't wait for the next loop.
        requests.post(f"{API_BASE}/reported",
                      json={"reported": current_state()},
                      headers=HEADERS, timeout=10)
    time.sleep(5)
```

Device firmware authors only need to understand the canonical capability vocabulary — no Tuya, no MQTT, no broker.

## Server-side changes needed

| Component | Change |
|---|---|
| device-service | New `device_keys` SQLModel + management endpoints + auth dependency |
| device-service | Promote `/internal/pending` and `/internal/reported` to `/protocol/v1/...` with the device-key auth path |
| device-service | Keep `INTERNAL_TOKEN` endpoints for tuya-bridge (legacy) — both can coexist |
| Terraform | No infra change. ALB listener rules already route `/api/v1/device/*` to device-service |
| docs/api-guide.md | New "Device protocol (v1)" section |

Rough scope: **300-400 LOC** including tests for the auth path.

## Coexistence with existing bridges

tuya-bridge and direct devices can run side by side. They both write to the same `devices.state` envelope through different endpoints; the shadow model doesn't care which adapter the data came from. A device-type column on `devices` (existing) tells the system which "kind" of device this is, and we'd add a column like `adapter_type ∈ {tuya_cloud, direct}` if the platform ever needed to make decisions based on it.

Practical fallout:
- A direct device's `tuya_device_id` is `NULL` — tuya-bridge's poll filter (`Device.tuya_device_id.is_not(None)`) already excludes it, so the bridge won't accidentally process direct-device state.
- A direct device hitting `/protocol/v1/pending` only sees its own row (filtered by `device_id` from the API key), so two devices can't claim each other's pending.

## Tradeoffs / what's deliberately out of scope

- **Bulk device registration / provisioning flow**: assume a human registers each device and copies the key into firmware. Mass provisioning (e.g., a factory burning the same key into a batch) is a follow-up.
- **Key rotation**: revoke + reissue requires getting the new key onto the device. For class-project scale, a console-paste workflow is fine. Production-grade rotation needs OTA or a paired secondary key.
- **mTLS as an alternative to API keys**: stronger security, but the device needs to host a private key and the platform needs a CA. Skip for v1.
- **Discovery / mDNS**: out of scope. Devices come with the platform URL baked in.
- **Telemetry beyond shadow state**: events like "motion detected" don't fit the desired/reported model. A separate `/protocol/v1/events` endpoint would handle these — defer until there's a concrete use case.

## Open questions

- Should the polling endpoint use long-polling (server holds the connection up to N seconds waiting for a command) to bridge the latency gap toward Pattern B without going full WebSocket? Probably yes if the v1 poll latency is unsatisfactory.
- Does it make sense to expose `/protocol/v1/state` (GET) as a way for the device to fetch reported state set by someone else, e.g., for boot-up reconciliation? Currently the device is authoritative for reported, but if a UI lets users edit reported directly (e.g., re-sync after a hardware swap), the device needs to know.
- Where do `device_keys` get stored — same RDS, or a separate secrets store? Same RDS is fine; the hash already protects against DB-dump exposure.

## Next steps when revisited

1. Design discussion on auth shape (API key vs mTLS) and key issuance UX.
2. Implementation order: `device_keys` schema → management endpoints → `/protocol/v1/reported` (write-only is the simplest entry point) → `/protocol/v1/pending` → docs.
3. Write a reference firmware sketch in actual hardware-friendly Python or C++.
4. Stand up a test device (Pi or ESP32) and exercise end-to-end before merging.
