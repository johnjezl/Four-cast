# Shelly Telemetry — Design

**Status**: design proposal for the first WiFi-device class on the platform. Coexists with `docs/device-protocol-design.md`; see "What we're inheriting" below.

## TL;DR

The first WiFi device on the platform is a **Shelly H&T Gen3** — battery-powered temperature & humidity sensor. Shelly devices run their own firmware (we can't put a polling loop on them) and the H&T specifically is asleep most of the time. The right model is:

- Device pushes outbound **HTTP webhooks** on each wake-up reading (Shelly Action with a templated body).
- New `POST /api/v1/device/protocol/v1/telemetry` endpoint receives the payload, persists a row per capability, publishes `device.telemetry` events to the bus.
- New `GET /api/v1/device/devices/{id}/telemetry` for read APIs.
- Per-device API key (the `device_keys` machinery from `device-protocol-design.md`) for auth.

Read-only sensor → no `desired` side → telemetry lives **alongside** the shadow envelope, not inside it.

## What we're inheriting from `device-protocol-design.md`

Wholesale adopted, no changes:

- **`device_keys` table** — same fields, same bcrypt hashing, same lifecycle (issue once / list / revoke).
- **`X-Device-Key` header auth** — same lookup-by-hash, populate `device_id` from FK, bump `last_used_at`, reject revoked.
- **Key management endpoints** — `POST/GET/DELETE /api/v1/device/devices/{id}/keys`.
- **`/api/v1/device/protocol/v1/...` namespace** for everything the device speaks to. (The doc anticipated this exact case under "Telemetry beyond shadow state" — this is the concrete use case it was deferring.)

**Scope extension:** Shelly keys get `scopes = ["write_telemetry"]` — a new scope not in the inherited default. The telemetry endpoint checks for this scope on every request; keys without it return `403`. Keys for future direct-integration devices keep the inherited `["read_pending", "write_reported"]`. A device can hold a key with both if it ever does both.

**Bcrypt performance note:** the inherited design uses bcrypt on every authenticated request. At Shelly H&T volume (one wake-up per device per hour) this is fine — single-digit CPU-ms per hit. For higher-volume future devices (a Shelly Plug streaming power every second), the bcrypt cost would become a hot path and we'd want to revisit (HMAC-SHA256 with a server-side pepper, or argon2 with a low cost factor). Not a v1 blocker; flagged so the implementation PR sizes the perf budget honestly.

What's new (this doc):

- The telemetry endpoint, table, and bus events.
- Sensor-only capabilities (`temperature`, `humidity`).
- Shelly-Action configuration recipe.

## Data model

### `device_telemetry` (long format)

```
device_telemetry
─────────────────────────────────
id            BIGSERIAL PK
device_id     UUID  FK → devices.id  ON DELETE CASCADE
capability    text                ("temperature", "humidity")
value         double precision
recorded_at   timestamptz         (device-supplied, if present)
received_at   timestamptz         default now()

INDEX (device_id, capability, received_at DESC)
UNIQUE INDEX (device_id, capability, recorded_at) WHERE recorded_at IS NOT NULL
```

`double precision` (8-byte IEEE 754) is sufficient precision for sensor readings and is smaller / faster than arbitrary-precision `numeric`. If a future device class needs exact decimal semantics (e.g., energy billing), that capability gets its own column type or table.

One row per `(device, capability, reading)`. A single Shelly webhook with both temperature and humidity becomes two rows. Long format makes `WHERE capability='temperature'` and per-capability aggregations trivial; the write volume is fine (H&T wakes on a configurable schedule, default ~hourly = ~48 rows/day per device).

**Idempotency.** The partial unique index above (skipping rows where `recorded_at IS NULL` because Postgres treats NULLs as distinct) lets the receive endpoint use `INSERT ... ON CONFLICT DO NOTHING` to absorb retried Shelly webhooks without creating duplicates. When the device doesn't supply `recorded_at`, dedup falls back to "we accept the duplicate and the consumer is expected to be idempotent" — flagged in "What's deferred" below.

### `devices` table — no new table for sensors

Sensors live in the existing `devices` table with `device_type_id = 'sensor'` (matching the existing `device_type_id` column on `devices`) and a new `metadata jsonb` column carrying vendor-specific fields like `{"subtype": "shelly_ht_gen3"}`. The existing `state` column is already JSONB — adding one more JSONB column for static device metadata is consistent and avoids growing the column count every time a new device class needs one bespoke field. Fields that don't apply to sensors (`tuya_device_id`, the `state` shadow envelope) stay nullable / empty. This keeps `GET /devices` returning a unified list regardless of actuator vs sensor.

**Prerequisite:** `device_type_id` is FK-linked to the existing `device_types` reference table. Adding `'sensor'` requires seeding a corresponding row in `device_types` (alongside the existing actuator types) as part of the schema migration — otherwise the first device insert fails the FK check.

**Coexistence with tuya-bridge:** sensors will have `tuya_device_id = NULL`, and tuya-bridge's existing poll filter (`Device.tuya_device_id.is_not(None)`) already excludes them. No change needed there.

## Capability vocabulary additions

| Capability    | Type     | Validated range                       | Setter? |
|---------------|----------|---------------------------------------|---------|
| `temperature` | `double` | Fahrenheit, `-40.0` to `180.0` (rejects clearly bad sensor readings) | no — sensor only |
| `humidity`    | `double` | percent, `0.0`–`100.0`                | no — sensor only |

**Canonical unit for temperature is Fahrenheit.** Shelly reports both °C and °F natively; we pick Fahrenheit at the canonical and template the Action body to send Fahrenheit. The API and bus speak Fahrenheit end-to-end. If/when this needs to be revisited for international devices, we'd add an explicit unit field rather than guessing.

Sensor-only capabilities mean: the canonical-capability metadata gains a `read_only: true` flag, the device-service shadow endpoints reject these in `PUT /state`, and the automation-service rule editor surfaces them only as triggers, not actions.

## Endpoints

### `POST /api/v1/device/protocol/v1/telemetry`

Device → platform. Auth: `X-Device-Key` header, must carry the `write_telemetry` scope.

```http
POST /api/v1/device/protocol/v1/telemetry
X-Device-Key: dvk_…
Content-Type: application/json

{
  "readings": {
    "temperature": 71.6,
    "humidity": 44.2
  },
  "recorded_at": "2026-05-12T20:30:00Z"   // optional, ISO8601
}
```

Server actions, in order:
1. **Auth.** Look up `X-Device-Key` by hash in `device_keys`; require row exists and `revoked_at IS NULL`. On failure → `401 Unauthorized`.
2. **Scope.** Require the key's `scopes` array contains `write_telemetry`. On failure → `403 Forbidden`.
3. **Validate readings.** Each capability value must parse as a number within its declared range (see capability table); out-of-range values are logged and skipped. Unknown capabilities are also logged and skipped (don't 400 — Shelly firmware updates could add fields).
4. **Persist.** `INSERT ... ON CONFLICT DO NOTHING` one row per accepted capability into `device_telemetry`. If *every* capability was filtered out at step 3 (nothing left to insert), skip persist + publish but still return `204` — a 400 here would flap on Shelly firmware adding new fields before we've registered them, and publishing an empty event would be noise to downstream consumers.
5. **Publish.** One `device.telemetry` event to the bus (see below). Skipped if step 4 inserted zero rows.
6. **Respond.** `204 No Content`. (Considered `202 Accepted` since the bus publish is asynchronous downstream, but we publish before responding, so `204` is honest.)

**Error responses:**

| Condition | Status |
|---|---|
| `X-Device-Key` missing or malformed | `401 Unauthorized` |
| Key not found in `device_keys` | `401 Unauthorized` |
| Key revoked (`revoked_at IS NOT NULL`) | `401 Unauthorized` |
| Key valid but lacks `write_telemetry` scope | `403 Forbidden` |
| Body malformed JSON / fails schema | `400 Bad Request` |

We return `401` rather than `403` for revoked/unknown keys so a key-rotation flow doesn't leak whether a stale key was ever real.

A "device row missing" case doesn't appear in the table because `device_keys.device_id` should be a FK to `devices.id` with `ON DELETE CASCADE` — deleting a device cascades to its keys, so a valid key cannot reference a missing device.

**Log scrubbing.** The `X-Device-Key` header must be filtered out of access logs, exception traces, and any request-dump diagnostics (e.g., a future Sentry integration). Implementation: a middleware that strips the header from the logged request representation before the access-log line is emitted, plus a hook that scrubs request headers from any exception serialization the platform does. Applies to both clouds — Cloud Run's request logs and ALB access logs both capture headers when configured to do so.

### `GET /api/v1/device/devices/{id}/telemetry`

Platform → user. Auth: existing JWT.

**Authorization scope (v1):** any valid JWT can read any device's telemetry. The platform doesn't currently track per-user device ownership — the existing `devices` table has no owner column and `GET /devices/{id}` doesn't gate on one either. Telemetry inherits the same behavior: telemetry-rows are accessible to any authenticated caller.

When platform-wide ownership lands (separate PR, separate doc), telemetry GET should follow the same rule as the other device endpoints. Until then, treating telemetry differently from the rest of the device API would be inconsistent and confusing.

Query parameters:
- `since` — ISO8601 timestamp (default: 24 hours ago)
- `capability` — optional filter (e.g., `temperature`)
- `limit` — default 1000, max 10000

Response:
```json
{
  "device_id": "…",
  "readings": [
    { "capability": "temperature", "value": 71.6, "recorded_at": "…", "received_at": "…" },
    { "capability": "humidity",    "value": 44.2, "recorded_at": "…", "received_at": "…" }
  ],
  "next_cursor": "…"
}
```

**Pagination:** cursor-based on `(received_at, id)` — not `received_at` alone, since two rows can share the same timestamp under burst inserts (both `now()`) and a timestamp-only cursor would skip or duplicate rows at page boundaries. The cursor is opaque (base64-encoded `received_at|id`); clients pass `cursor=<opaque>` on the next request.

## Event bus

One `device.telemetry` event per webhook hit. Payload carries all capabilities together so the consumer can decide what to do with each.

Example, device-supplied `recorded_at`:

```json
{
  "event": "device.telemetry",
  "device_id": "1a2b…",
  "device_type": "sensor",
  "readings": { "temperature": 71.6, "humidity": 44.2 },
  "recorded_at": "2026-05-12T20:30:00Z",
  "received_at": "2026-05-12T20:30:02Z"
}
```

Example, device omitted `recorded_at` — fallback makes the two equal:

```json
{
  "event": "device.telemetry",
  "device_id": "1a2b…",
  "device_type": "sensor",
  "readings": { "temperature": 71.6, "humidity": 44.2 },
  "recorded_at": "2026-05-12T20:30:02Z",
  "received_at": "2026-05-12T20:30:02Z"
}
```

**`recorded_at` on the bus is always populated**, falling back to `received_at` if the device didn't supply one. This decouples the bus contract from the still-open DB question of whether to store NULL or `received_at` in the `recorded_at` column — consumers always have a usable timestamp regardless.

Consumers:
- **analytics-service** — same idempotent insert pattern it already uses for shadow events; new aggregations on the telemetry stream.
- **automation-service** — rules can match on any reading in the payload (`temperature > 80` triggers when the temperature key is present). Rule evaluators should be idempotent against duplicate events (see "Idempotency" above): in the no-`recorded_at` case the receive endpoint can't dedup at the row level, and a retried Shelly webhook will produce a duplicate bus event.

Single-event-per-hit avoids fanout amplification (no 2× messages for a 2-capability Shelly hit).

**Back-pressure.** If the bus consumer is down, telemetry events accumulate in the queue/topic. Both SQS (default 4-day retention) and Pub/Sub (default 7-day retention) buffer enough to ride out a multi-hour outage on H&T-scale volume. Higher-volume future devices would force re-evaluation. Out of scope for v1.

## Shelly-side configuration

Per device, one-time setup via the Shelly web UI (or the Shelly Cloud API):

**Action: "On sensor report"**
- URL: `https://api.smarthome.example/api/v1/device/protocol/v1/telemetry` — **HTTPS is required**; the receive endpoint must reject `http://` traffic so the API key in the header isn't sent in cleartext.
- Method: `POST`
- Headers:
  - `X-Device-Key: <issued at registration>`
  - `Content-Type: application/json`
- Body (templated):
  ```json
  {
    "readings": {
      "temperature": ${temperature_F},
      "humidity": ${humidity}
    },
    "recorded_at": "${ts}"
  }
  ```

Variables `${temperature_F}`, `${humidity}`, `${ts}` are placeholder names — **the exact Shelly Gen3 RPC syntax must be verified against firmware** before the onboarding flow templates this snippet for real. Step 9 of "Next steps" (end-to-end test against a real H&T) confirms the names; the implementation should treat the template above as a sketch, not a contract.

For onboarding, the platform's `POST /api/v1/device/devices` flow would return both the device's API key (plaintext, once) and a copy-paste-ready Shelly Action JSON the user pastes into the device's web UI.

## Server-side work

| Component       | Change |
|-----------------|--------|
| device-service  | `device_keys` model + key-management endpoints + `X-Device-Key` auth dependency (per `device-protocol-design.md`); add `write_telemetry` scope alongside the inherited defaults |
| device-service  | `device_telemetry` model (with the partial unique index for idempotency) + `/protocol/v1/telemetry` POST + `/devices/{id}/telemetry` GET |
| device-service  | Log-scrubbing middleware that strips `X-Device-Key` from access logs and exception traces |
| device-service  | Capability metadata: `temperature`/`humidity` registered with `read_only: true` and validated ranges; `PUT /state` rejects them |
| device-service  | `device_type_id = 'sensor'` honored in `GET /devices` listing; add `metadata jsonb` column to `devices` for the per-device-class subtype field |
| device-service  | Publish `device.telemetry` to the bus on telemetry receive (with `recorded_at` fallback to `received_at`) |
| analytics-service | Consume `device.telemetry`; new aggregation tables (`telemetry_daily_avg`, etc.) — separate PR |
| automation-service | Allow telemetry capabilities as triggers — separate PR |
| Terraform       | No infra change — ALB / Cloud Run paths already route `/api/v1/device/*` to device-service |
| docs/api-guide.md | New "Device protocol v1 — telemetry" section |

Rough scope: **~400–500 LOC** including tests for the auth path and the receive endpoint. Analytics and automation hookup are follow-up PRs.

## What's deferred

- **Multi-vendor telemetry**: Shelly's payload shape happens to match our endpoint because we template it on the device side. A second vendor with a fixed (untemplatable) payload would need a vendor-specific adapter — defer until we have one.
- **Backfill / batch upload**: Shelly is real-time push; no historical backfill story needed yet.
- **Anomaly detection / alerting**: out of scope. analytics-service can grow this later.
- **Retention policy**: H&T volume is trivial. Revisit when motion / button sensors land.
- **Telemetry-driven shadow updates**: in v1, sensor readings are independent of any actuator's shadow. If a future use case wants "thermostat sets desired temp based on a sensor's reading," that's automation-service territory, not a new path here.
- **Idempotency without `recorded_at`**: when the device doesn't supply a recorded timestamp, the partial unique index can't catch duplicates and a retried Shelly webhook produces a duplicate row + duplicate bus event. Consumers must be idempotent. A future option is a request-ID header (`X-Idempotency-Key`) but Shelly's Action templates don't natively support generating one per-fire, so deferred.
- **Bus consumer back-pressure** at higher device volumes: H&T-scale is comfortably within SQS/Pub/Sub default retention windows. Revisit if a high-rate device (streaming power meter) lands.

## Open questions

- Should the issuance endpoint (`POST /devices/{id}/keys`) generate the Shelly Action JSON snippet inline in its response, or is that a separate `GET /devices/{id}/onboarding-snippet` endpoint? Inline is more convenient; separate keeps the keys endpoint generic for non-Shelly devices.
- For `recorded_at` *in the database* when the device doesn't supply it: store NULL or store `received_at`? (Bus side is already decided — always populated with fallback.) **This decision is structurally linked to the deferred "Idempotency without `recorded_at`" item below**: picking `received_at` makes the partial unique index effectively a full unique index and dedup covers every webhook hit — the deferred problem evaporates. Picking NULL keeps it real (consumers must stay idempotent). NULL is more honest about provenance; `received_at` is simpler and dedup-complete. Leaning NULL today, but the trade-off should be made consciously with that linkage in mind.
- Capability namespace: as the platform grows, `temperature` could mean indoor (sensor), thermostat setpoint, or oven (actuator). Do we want to namespace (`ambient.temperature`, `thermostat.setpoint`) now, or rely on `device_type` to disambiguate? Defer until the second device class actually conflicts.
- Should `device_telemetry` carry an explicit `unit` column? The capability table declares the canonical unit per capability (Fahrenheit for `temperature`, percent for `humidity`), so the unit is recoverable from `capability` alone. A `unit` column would be redundant today and impossible to retrofit cleanly if a future capability is ever stored under multiple units (e.g., `temperature` rows in both F and C). Leaning no, but flagging because once telemetry rows exist, backfilling a per-row unit is not possible without device firmware metadata we won't have kept.

## Next steps when approved

1. Schema migration: `device_keys` and `device_telemetry` tables.
2. `X-Device-Key` auth dependency + key-management endpoints.
3. `POST /protocol/v1/telemetry` (write-only is the smallest first slice).
4. `GET /devices/{id}/telemetry`.
5. Bus publish on telemetry receive.
6. Capability metadata flag for `read_only` + sensor handling in existing endpoints.
7. Onboarding snippet (Shelly Action template) generation.
8. `docs/api-guide.md` update.
9. End-to-end test against a real Shelly H&T before merge.
