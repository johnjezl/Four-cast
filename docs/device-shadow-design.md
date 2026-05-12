# Device Shadow Redesign — Postgres-Backed, Broker-Free

## TL;DR

Move device shadow state from AWS IoT Core into the Postgres `devices.state` JSONB column we already have. Replace the two Lambda bridges with a single long-running `tuya-bridge` Fargate service that device-service talks to over HTTP. Delete `modules/iot/` entirely. The result is the same external API contract, ~480 fewer lines of Terraform, ~$13/mo more in idle cost (the new Fargate task; IoT Core was free-tier today), and an architecture that ports to Azure or GCP by swapping cluster + Postgres providers — no IoT service in the substitution table.

## Goals

- **Cloud portability**: nothing in the runtime path that's cloud-specific. Postgres + HTTP + container scheduler is universal.
- **Same external API**: `/api/v1/device/devices/{id}/state` and the convenience endpoints behave identically. The Tuya light still responds to `POST /on`.
- **Smaller blast radius**: fewer moving parts, no shadow-document re-entry concerns, no IAM matrix between IoT and Lambda.

## Non-goals

- Supporting MQTT-speaking devices. We have none. If we ever ship one, EMQX-as-broker is the follow-up; this design doesn't preclude that.
- Real-time push to clients. We're keeping the current poll-based model.
- High-throughput telemetry. Postgres JSONB is fine for state at ~1 write/device/minute; if we ever need 100 writes/sec/device, revisit.

## Architecture

```
              ┌────────────────────────────────────────┐
              │           ALB (per cloud)              │
              └──────────────┬─────────────────────────┘
                             │
        ┌────────────────────┼────────────────────┬───────────────┐
        │                    │                    │               │
┌───────▼─────┐    ┌─────────▼───────┐  ┌────────▼─────┐  ┌──────▼──────┐
│ device-svc  │    │ automation-svc  │  │ user-svc     │  │ analytics-  │
│             │    │                 │  │              │  │   svc       │
│ owns shadow │    │ rules           │  │ auth/JWT     │  │ metrics     │
└──┬──────┬───┘    └─────────┬───────┘  └──────────────┘  └─────────────┘
   │      │                  │
   │ HTTP │ (commands)       │ HTTP (state reads)
   │      │                  │
   │      ▼                  ▼
   │  ┌─────────────────────────┐
   │  │ tuya-bridge (Fargate)   │
   │  │  · POST /command        │  ← invoked by device-svc on PUT state
   │  │  · async poll loop      │  → POST /reported back to device-svc
   │  └────────────┬────────────┘
   │               │ HTTPS
   │               ▼
   │           Tuya Cloud
   │
   ▼
┌────────────────────┐
│  RDS Postgres      │
│  devices.state     │  ← single source of truth
└────────────────────┘
```

Two new HTTP edges. No broker, no queue, no IoT service.

## Data model

**No schema change required.** `Device.state` already exists as a JSONB column (`device-service/app/main.py:81`). It currently holds whatever last shadow document the IoT data plane returned, treated as cache. We promote it to source of truth.

If we want explicit `desired`/`reported` separation (recommended for parity with how operators think about shadows), evolve the column shape:

```json
{
  "desired":  { "switch_led": true, "bright_value_v2": 800 },
  "reported": { "switch_led": true, "bright_value_v2": 800, "last_sync": 1715472000 },
  "version":  42
}
```

A monotonic `version` integer gives optimistic-concurrency on writes (`UPDATE … WHERE version = $expected`) — replaces the IoT shadow's built-in version field. `last_sync` (epoch seconds) carries over from today's Lambda; tuya-bridge writes it on each successful poll and the API echoes it so clients can detect stale state.

The actual OCC guard, omitted from the larger example below for brevity:

```python
result = await session.execute(
    update(Device)
    .where(Device.id == device.id)
    .where(Device.state["version"].astext.cast(Integer) == expected_version)
    .values(state=new_state)
)
if result.rowcount == 0:
    raise HTTPException(409, "shadow modified concurrently; retry")
```

## Component changes

### device-service (largest delta)

Replace the IoT helpers with Postgres operations and an HTTP client to tuya-bridge.

```python
# Was: boto3 iot_data calls
async def update_device_state(
    device: Device,
    desired: dict,
    session: AsyncSession,
) -> dict:
    current = device.state or {"desired": {}, "reported": {}, "version": 0}
    current["desired"] = {**current.get("desired", {}), **desired}
    current["version"] = current.get("version", 0) + 1
    device.state = current
    await session.commit()

    # Fire-and-forget: the API returns as soon as the desired write is durable.
    # tuya-bridge owns retries, command translation, and reporting back.
    if device.tuya_device_id:
        asyncio.create_task(httpx_client.post(
            f"{TUYA_BRIDGE_URL}/command",
            json={"tuya_device_id": device.tuya_device_id, "desired": desired},
            timeout=5.0,
            headers={"X-Internal-Token": INTERNAL_TOKEN},
        ))
    return current
```

Add one new endpoint for the bridge to push reported state back:

```python
# device-service/app/main.py
@app.post("/api/v1/device/internal/reported", include_in_schema=False)
async def receive_reported_state(
    payload: ReportedStateUpdate,
    session: AsyncSession = Depends(get_session),
):
    """Called by tuya-bridge after polling Tuya. Updates reported and clears
    matching desired keys."""
    device = await session.scalar(
        select(Device).where(Device.tuya_device_id == payload.tuya_device_id)
    )
    if not device:
        return {"status": "unknown_device"}

    state = device.state or {"desired": {}, "reported": {}, "version": 0}
    state["reported"] = {**state.get("reported", {}), **payload.reported}
    # Clear desired keys whose reported value now matches (delta-clear semantics)
    state["desired"] = {
        k: v for k, v in state.get("desired", {}).items()
        if state["reported"].get(k) != v
    }
    state["version"] = state.get("version", 0) + 1
    device.state = state
    await session.commit()
    return {"status": "ok"}
```

Internal endpoint, not exposed via API Gateway; protected by VPC + a shared `X-Internal-Token` header (see the **Service-to-service authentication** section below).

Remove: `get_iot_client`, `get_device_shadow`, `update_device_shadow`, `IOT_ENDPOINT` env var, `boto3` IoT dependency.

### tuya-bridge (new service, ~150 lines of Python)

Move the existing `aws/terraform/modules/iot/lambda/handler.py` to `aws/services/tuya-bridge/app/main.py` with two surface changes:

1. **From Lambda handlers to FastAPI + async task.**
   - `send_command_to_tuya` becomes `POST /command` handler.
   - `poll_tuya_devices` becomes a background task started on app startup, running on a 60s interval (`asyncio.create_task` + `asyncio.sleep`).
2. **Output target.** Instead of `iot_client.update_thing_shadow(reported)`, call `device-service /internal/reported`.

Keep the TuyaCloud client class verbatim — that's the value we're preserving.

### Service-to-service authentication

device-service and tuya-bridge share a single secret `INTERNAL_TOKEN` (a `random_password` resource in Terraform), passed via env var to both tasks. Every internal call carries `X-Internal-Token: <value>`; missing or mismatched headers return 401. The token rotates with `terraform apply` — both services pick up the new value on next deploy. This is intentionally minimal: VPC isolation is the primary boundary, the token is defense-in-depth against accidental exposure. Per-service JWTs are a follow-up if/when these endpoints leave the VPC.

### Failure handling

If tuya-bridge is unreachable when device-service commits a desired write, the write succeeds in Postgres but the command never reaches Tuya. To avoid silent drops, tuya-bridge runs a reconciliation pass on every poll tick: fetch all devices with `desired != reported` from device-service (`GET /api/v1/device/internal/pending`), and re-issue any pending commands to Tuya. Worst-case command latency on bridge outage is one poll interval (~60s) instead of "lost forever."

If Tuya itself rejects or times out a command, tuya-bridge logs the failure and skips the optimistic `POST /reported` — the next poll catches up with real state and the user sees the unconverged `desired` until they retry.

### automation-service, analytics-service, user-service

No code changes. They don't talk to IoT today.

### Terraform

**Delete** `aws/terraform/modules/iot/` (≈480 lines).

**Add** `tuya-bridge` to `local.services` in `aws/terraform/main.tf`:

```hcl
tuya-bridge = {
  port        = 8005
  cpu         = 256
  memory      = 512
  health_path = "/health"
  owner       = "Platform"
}
```

The existing `modules/ecs/` already builds and pushes any service in that map — no module changes needed.

**Remove** from `main.tf`:
- `module "iot" { ... }` block
- IoT-related variables (`tuya_device_ids`, `tuya_client_id`, `tuya_client_secret`, `tuya_region` move into the bridge's env vars, sourced from `secrets_manager` for the secret pair)
- `iot_endpoint` and `device_events_queue` env vars passed to ECS

**Add** to the ECS task definition for `device-service`: `TUYA_BRIDGE_URL = http://tuya-bridge.<svc-discovery>:8005`. For tuya-bridge: `DEVICE_SERVICE_URL = http://device-service.<svc-discovery>:8001` and a Secrets Manager mount for Tuya credentials.

**Net Terraform change**: ~480 lines deleted, ~30 lines added.

### Event fan-out (was: SQS via shadow_to_sqs rule)

The `shadow_to_sqs` IoT rule fans state changes to SQS for analytics. Two options post-migration:

| Option | Portability | Effort |
|---|---|---|
| Keep SQS; device-service publishes directly after `commit` | AWS-specific; needs Service Bus / Pub Sub abstraction for other clouds | Already implemented in `publish_device_event` |
| Drop the queue; analytics-service polls device-service for state-change events via a `?since=<version>` query | Fully portable | Small change to analytics-service |

Recommend keeping SQS for now (`publish_device_event` already does this) and abstracting only when the second cloud lands.

## Event flow walkthroughs

### A. User sets state via API

1. `PUT /api/v1/device/devices/{id}/state` → device-service.
2. device-service updates `devices.state.desired`, increments version, commits.
3. device-service fire-and-forget `POST /command` to tuya-bridge with `{tuya_device_id, desired}`. **API returns to the user here.**
4. tuya-bridge calls Tuya Cloud `POST /v1.0/iot-03/devices/{id}/commands`.
5. **Optimistically**, tuya-bridge `POST /internal/reported` to device-service using the Tuya-coded keys from step 4 as reported state (same pattern as the Lambda in PR #2). This collapses the delta immediately so a subsequent GET reflects the change without waiting for a poll tick. The next poll loop overwrites with Tuya's authoritative state if anything diverged.
6. device-service writes reported, clears matching desired keys via the OCC-guarded update.
7. (Optional) device-service publishes to SQS for analytics.

Steps 1–3 return to the user in <100 ms (Postgres write only). Steps 4–6 typically complete in 1–3 s, dominated by the Tuya round-trip; the user observes the converged state on their next GET.

### B. Background reconciliation

1. tuya-bridge's 60s loop fetches all devices: `GET /v2.0/cloud/thing/space/device` (existing logic).
2. For each device, fetches status: `GET /v2.0/cloud/thing/{id}/shadow/properties`.
3. `POST /internal/reported` to device-service.
4. Catches user-side changes (someone hit the bulb's physical switch) and device-side drift.

### C. New device discovered on Tuya

Same as today: tuya-bridge calls device-service's existing `POST /api/v1/device/devices` with `tuya_device_id` set, which upserts.

## Multi-cloud portability

What ports unchanged:

- Postgres (RDS / Azure Database for PostgreSQL / Cloud SQL)
- All four microservices + tuya-bridge container images
- HTTP service-to-service via cluster DNS

What's cloud-specific:

| Concern | AWS | Azure | GCP |
|---|---|---|---|
| Container scheduler | ECS Fargate | Container Apps | Cloud Run |
| Load balancer | ALB | Application Gateway | HTTPS LB |
| Service discovery | ECS Service Connect / Cloud Map | Container Apps internal ingress | Cloud Run service URLs |
| Secret store | Secrets Manager | Key Vault | Secret Manager |
| (Optional) event queue | SQS | Service Bus | Pub/Sub |

Each is a different Terraform module, but the *contract* (image, port, env vars, secret bindings) is identical. No IoT Core in any of these substitutions — that's the win.

## Migration path

1. **Add `tuya-bridge` service** with the new HTTP surface; deploy alongside existing IoT module. (No traffic yet.)
2. **Add internal `/reported` and `/pending` endpoints to device-service**.
3. **Feature flag**: `SHADOW_BACKEND = iot | postgres`. device-service routes shadow ops by flag. Note that device-service carries both implementations during this phase — accept the temporary complexity in exchange for a reversible cutover.
4. **Switch traffic** by toggling the flag in env vars.
5. **Verify** by exercising `test_apis.sh` and physical-light toggle.
6. **Delete** `modules/iot/`, the Lambda code, IoT env vars, and the feature flag.

Step 1-4 are reversible; step 6 is one-way.

## Tradeoffs / what we lose

- **No MQTT pub/sub topology**. If a future device speaks MQTT natively, we'd need EMQX (or revive IoT Core). Acceptable now; the project has zero MQTT-capable devices.
- **Polling-based reconciliation for out-of-band changes**. AWS IoT's MQTT delta is push; ours is a 60s poll. Latency for "user toggles bulb physically → API GET reflects new state" goes from seconds to up to 60s. In-band writes (user calls our API) converge in 1–3s via the optimistic-report step. Worth flagging to UI consumers — a UI that auto-refreshes every minute is fine; one that expects sub-second push-style updates is not.
- **No telemetry-to-Timestream path** for free. We were never using Timestream (`enable_timestream = false` by default), so this is a paper loss only.
- **Operational responsibility for the bridge**. tuya-bridge is now a long-running container we maintain, not a managed Lambda. Counterpoint: the four microservices are already that, so we're not adding a category of work, just one more instance.
- **~$13/mo idle cost** for the new Fargate task. IoT Core is free-tier at our scale (2 devices, ~86K shadow ops/month), so this migration costs more, not less. The win is portability and architectural clarity, not dollars.

## Out of scope for this design

- Per-cloud queue abstraction (Service Bus / Pub Sub). Address when the second cloud lands.
- Real-time push to UI clients (WebSocket / SSE). Separate design.
- Multi-region active-active. Same.
- Hardening tuya-bridge → device-service authentication beyond a shared internal token. JWT-svc-to-svc is a follow-up if we go to production.
