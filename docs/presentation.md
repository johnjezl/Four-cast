# Smart Home Hub Platform — Presentation Content

Target length: ~10 minutes presentation + live demo. ~40s per slide.

Each slide below is content only — no design direction. ASCII diagrams
are intended as logical reference for Claude Design to redraw.

---

## Slide 1 — Title

**Smart Home Hub Platform**
A portable microservice control plane for IoT devices

CS-385 Group Project

(Team names go here)

---

## Slide 2 — What We Built

A device control plane deployed on **two clouds** with **identical service code**.

- 5 microservices behind a shared SDK abstraction
- Same Python code runs on AWS (ECS Fargate) and GCP (Cloud Run); cloud-specific bits live behind two protocols (`EventBus`, `SecretStore`)
- Adapter chosen at runtime from a `CLOUD_PROVIDER` env var — no recompile, no rebuild
- Terraform-managed infra per cloud
- 44 end-to-end API tests pass on both deployments
- Real device control: discovery + on/off + brightness, end-to-end through Tuya Cloud

```
        ┌──────── service code (identical) ────────┐
        │                                          │
        │     shared/cloud/  ◄── runtime switch    │
        │      ├── aws.py    SqsEventBus / SM      │
        │      └── gcp.py    PubSubEventBus / SM   │
        │                                          │
AWS ECS ┴──────────────────────────────────────────┴── GCP Cloud Run
```

---

## Slide 3 — What We Didn't Design For

Conscious scope cuts to keep the project demonstrable:

- **High availability**
  - Zonal Cloud SQL / single-AZ RDS
  - Single region everywhere
  - No multi-region failover
- **Auto-scaling**
  - Fixed `min_instances` / `max_instances` per service
  - No queue-depth or request-rate driven scaling
- **Production hardening**
  - Manual secret rotation
  - DB backups disabled (cost)
  - No DR runbook
- **Multi-tenancy**
  - One shared deployment; no per-customer isolation

Trade-off: showing the *architecture* works on two clouds, not showing it can survive a region going down.

---

## Slide 4 — device-service (the shadow)

The system of record for every device's intended and observed state.

```
   Public API                          Internal (INTERNAL_TOKEN)
        │                                       │
        ▼                                       ▼
┌────────────────────────────────────────────────────────┐
│                    device-service                      │
│                                                        │
│  /api/v1/device/devices       CRUD + list              │
│  /api/v1/device/.../state     read/write desired state │
│  /api/v1/device/.../on|off    quick controls           │
│  /api/v1/device/.../command   capability commands      │
│                                                        │
│  /internal/pending            (bridges pull commands)  │
│  /internal/reported           (bridges push state)     │
└────────────────────────────────────────────────────────┘
         │                              │
         ▼                              ▼
   Postgres shadow               Event bus
   {desired, reported,           (publishes state changes
    version, retry_count,         for analytics-service)
    last_attempted}
```

- Shadow envelope drives convergence: bridges retry until `desired == reported`
- All other services treat device-service as the single source of truth

---

## Slide 5 — What is Tuya?

The vendor cloud our smart bulbs talk to.

- **Tuya** is one of the largest IoT platforms in the world — the company behind a huge slice of the "white-label" smart-home hardware sold on Amazon. A lot of devices branded by other companies are Tuya devices under the hood.
- Devices ship preconfigured to phone home to **Tuya Cloud**, which exposes a public HTTP API for third-party integrations (OAuth-style: client ID + secret + linked user account).
- **What we get from Tuya:**
  - Device discovery (list of devices on a linked Tuya account)
  - Read current device state
  - Send commands (on/off, brightness, color, etc.)
- **What we don't get:**
  - Real-time push — we have to poll
  - A cross-vendor abstraction — Tuya devices only
  - Free service — there's a rate limit; commercial use needs a paid tier

Why this matters for the project:
- Tuya is the reason we can demo with **real hardware** without writing firmware or running our own MQTT broker.
- It also frames the next slide: `tuya-bridge` is the *only* part of our code that knows Tuya exists. Everything else just sees the device shadow.

```
       phone, app                    our platform
         │                              │
         └────► Tuya Cloud ◄────────────┘
                  │
                  ▼
         physical devices on wifi
         (bulbs, plugs, sensors…)
```

---

## Slide 6 — tuya-bridge

The integration layer between our cloud and Tuya's vendor cloud.

```
   Cron / scheduler                    User commands
        │                                  │
        ▼                                  ▼
   /poll  ◄────────────────  /command  ◄── device-service
        │                                  │
        ▼                                  ▼
   ┌────────────────────────────────────────────────┐
   │                tuya-bridge                     │
   │                                                │
   │  Pulls /internal/pending  ─► sends to Tuya     │
   │  Reads device state from Tuya  ─► /internal/   │
   │                                    reported    │
   └────────────────────────────────────────────────┘
                          │
                          ▼
                   Tuya Cloud API
                   (OAuth, signed requests)
```

- Holds the Tuya OAuth credentials (Secret Manager / Secrets Manager)
- Stateless — every poll/command call is independent
- The only service that knows what "Tuya" is; everyone else just speaks shadow

---

## Slide 7 — user-service

Auth + identity for the whole platform.

```
   Public                              Other services
      │                                      │
      ▼                                      │ (verifies JWT signature locally)
┌─────────────────────────────────────┐      │
│            user-service             │      │
│                                     │      │
│  /register   /login    /logout      │      │
│  /me         /preferences           │      │
│  /api-keys                          │      │
└─────────────────────────────────────┘      │
            │                                │
            ▼                                │
   Postgres (users, hashed pw,               │
   api-keys)                                 │
            │                                │
            └── JWT signed with JWT_SECRET ──┘
                (Secret Manager / Secrets Manager)
```

- Issues JWTs; all other services verify them without calling back
- `JWT_SECRET` is shared via the cloud's secret store at container start
- API-key alternative for service-account-style access

---

## Slide 8 — automation-service

Rule engine for "if X then Y" device behavior.

```
            User-defined rules                  Templates
                  │                                │
                  ▼                                ▼
   ┌──────────────────────────────────────────────────────┐
   │              automation-service                      │
   │                                                      │
   │  /rules           CRUD                               │
   │  /rules/.../enable | disable | trigger               │
   │  /templates       built-in starter rules             │
   │  /history         past rule firings                  │
   └──────────────────────────────────────────────────────┘
                  │                                │
                  ▼                                ▼
       device-service                        Postgres
       (issues commands when                 (rules, history)
        triggers fire)
```

- Rules are user-owned objects, persisted in Postgres
- Trigger evaluation is request-driven (`/trigger`) — no background loop in this iteration
- Templates let users adopt curated rules without building them from scratch

---

## Slide 9 — analytics-service

Read-only consumer of the event stream.

```
   Event bus subscription              Read APIs
        │                                  │
        ▼                                  │
   ┌──────────────────────────────────────────────────────┐
   │              analytics-service                       │
   │                                                      │
   │  Consumes device-event messages (Pub/Sub or SQS)     │
   │  Idempotent inserts (ON CONFLICT DO NOTHING)         │
   │                                                      │
   │  /devices/summary    aggregate usage                 │
   │  /devices/.../metrics                                │
   │  /usage              platform-wide                   │
   │  /slos    /devex     /maturity                       │
   └──────────────────────────────────────────────────────┘
                          │
                          ▼
                   Postgres (analytics tables)
```

- Pure consumer — never writes back to the device shadow
- Ack semantics are cloud-specific (DLQ on AWS, dead-letter topic on GCP) but the consumer code is identical

---

## Slide 10 — Per-Platform Services Comparison

| Concern               | AWS                         | GCP                                  |
|-----------------------|-----------------------------|--------------------------------------|
| Compute               | ECS Fargate behind ALB      | Cloud Run v2 (per-service URLs)      |
| Container registry    | ECR                         | Artifact Registry                    |
| Database              | RDS Postgres (private VPC)  | Cloud SQL Postgres (Auth Proxy)      |
| Event bus             | SQS queue + DLQ + redrive   | Pub/Sub topic + sub + DL topic       |
| Secrets               | Secrets Manager             | Secret Manager                       |
| Service identity      | One task role + scoped role | One service account per service      |
| Inbound               | API Gateway → ALB           | Direct `*.run.app` per service       |

How these choices shaped the design:
- **ALB is one URL → API Gateway sits in front uniformly.** Cloud Run gives N URLs → no shared gateway, so we leaned on app-level `INTERNAL_TOKEN` for inter-service auth on both clouds (uniform behavior).
- **VPC vs Auth Proxy.** RDS lives in private subnets; Cloud SQL is reached over the public endpoint via the Auth Proxy unix socket. `DATABASE_URL` format differs but service code doesn't change.
- **Per-cloud identities are isomorphic** — one runtime principal per service in both, scoped to exactly what that service needs.

---

## Slide 11 — Per-Platform Cost Comparison

Rough monthly cost for the demo stack as deployed (single region, demo sizing).

**AWS — ~$140 / month**
- ECS Fargate (5 svc × small task): ~$75
- ALB: ~$20
- RDS db.t3.micro: ~$15
- NAT Gateway (for private subnet egress): ~$32
- API Gateway, SQS, ECR: free tier

**GCP — ~$110 / month (at `min_instances = 2`)**
- Cloud Run (10 always-allocated vCPU): ~$100
- Cloud SQL db-f1-micro: ~$10
- Pub/Sub, Artifact Registry, Secret Manager: free tier / negligible

**GCP — ~$15 / month at `min_instances = 0`**
- Pay-per-request; cold-start latency on first hit
- Right setting for an idle stack between demos

Take-away: at demo scale the two clouds are within ~25% of each other; the bigger lever is `min_instances`, not cloud choice.

---

## Slide 12 — Gotchas We Hit

**Shared**
- Build context must be the repo root so `COPY shared/` works.
- Image-rebuild hash must include `shared/` or service images go stale silently.

**AWS-specific**
- ECS task → ALB target group health-check timing required `health_check_grace_period_seconds` tuning.
- Secret rotation requires a new task definition revision — Secrets Manager updates don't reach running tasks.

**GCP-specific**
- **Self-referential `for_each`.** Terraform forbids a `for_each` instance referencing a sibling instance. Forced **3** Cloud Run resource blocks (`main`, `device_service`, `tuya_bridge`).
- **`PORT` is reserved** in Cloud Run env — setting it explicitly is rejected.
- **Cross-service URLs are a post-create patch** for `tuya-bridge` (`null_resource` running `gcloud run services update`) because `device-service` and `tuya-bridge` reference each other.
- **Lazy SDK imports** required at the adapter module level — the GCP adapter pulled in both `pubsub_v1` and `secretmanager` at import, breaking services that only ship one.
- **Destroy ordering.** Cloud Run delete returns before connections drain; SQL DB drop fails with "is being accessed." Fix: a destroy-time provisioner that restarts the SQL instance to nuke all sessions before the drop.

---

## Slide 13 — Why No Global LB on GCP?

**What a Global External LB + Serverless NEG would buy us:**
- Single domain (`api.smarthome.example.com`) in front of all 5 services
- Multi-region failover (if we ran in multiple regions)
- Cloud Armor WAF, IAP, edge caching

**Why we skipped it:**
- We're **single region** — no failover benefit to capture
- Adds base cost (~$20/mo) and serverless-NEG config complexity per service
- App-level `INTERNAL_TOKEN` already handles inter-service auth uniformly

**AWS-side equivalent would not be free either:**
- A single domain across services on AWS needs **Route 53 + CloudFront + ACM** — not just "one LB."
- We get a single domain on AWS through API Gateway, but only because API Gateway is itself a managed edge layer.

Take-away: Global LB is the right answer for a *production*, multi-region deployment. For a single-region demo, the complexity isn't earned.

---

## Slide 14 — Why We Rolled Our Own IoT Layer

**Options we considered:**
- **AWS IoT Core** — MQTT broker, per-message billing, AWS-locked.
- **GCP IoT Core** — **deprecated August 2023**. Not an option on the GCP side.
- **Azure IoT Hub** — same shape as AWS IoT Core, also vendor-locked.

**Why a managed IoT service didn't fit:**
- Locks the integration layer to one cloud — breaks the "same code on both clouds" property that the whole project is built around.
- Pricing is per-message at scale; not free at low scale either.
- MQTT-broker semantics force a different programming model than the rest of our HTTP-and-event-bus stack.

**Our approach: `tuya-bridge` as a regular microservice**
- Speaks the vendor cloud's HTTP API (Tuya in our case; swap-able)
- Pulls commands and pushes reported state through the same `/internal/*` endpoints any future direct-device adapter would use
- Same code on AWS and GCP

**Trade-off accepted:**
- ~2 s polling latency vs ~100 ms MQTT push
- Fine at homework / hobby scale; would need a real broker beyond ~thousands of devices.

---

## Slide 15 — Live Demo

Coming up:
- `terraform output service_urls` — show the deployed stack
- `./gcp/test_apis.sh` — the 44-test sweep, runs in seconds
- Direct device control via `curl` against the real `*.run.app` URL
- Lights actually turning on and off in the room

Same code, same demo, both clouds.
