# Porting the SmartHome Hub to a new cloud

Quick guide for adding a third cloud (Azure, OCI, whatever) alongside
`aws/` and `gcp/`. Reading time: 5 minutes. Implementation time: 2–4
focused days including review cycles and a real-cloud smoke test —
the GCP port spanned six PRs and a few novel issues surfaced only on
first real apply.

## What's already abstracted

Service code (`*/services/*/app/`) is **identical** between AWS and
GCP. The only cloud-specific surface lives behind two protocols in
`shared/cloud/`:

| Protocol | What it does | AWS impl | GCP impl |
|---|---|---|---|
| `EventBus` | publish / receive / ack events | `SqsEventBus` (boto3) | `PubSubEventBus` (google-cloud-pubsub) |
| `SecretStore` | read a secret value by name | `SecretsManagerStore` | `SecretManagerStore` |

The adapter is picked at runtime from `CLOUD_PROVIDER`. New clouds add
a new module (`shared/cloud/azure.py`) and a new branch in
`shared/cloud/__init__.py`'s `event_bus()` / `secret_store()`
factories. Adapter imports are lazy, so containers don't need SDKs
they won't use.

That's the whole code-side contract. Everything else is infrastructure
plumbing.

## Resource mapping

| Concern | AWS | GCP | Azure (suggested) |
|---|---|---|---|
| Compute | ECS Fargate behind ALB | Cloud Run v2 | Container Apps |
| Container registry | ECR | Artifact Registry | Azure Container Registry |
| Database | RDS Postgres | Cloud SQL Postgres (via Auth Proxy) | Azure DB for Postgres Flexible Server |
| Event bus | SQS + DLQ + redrive | Pub/Sub topic + sub + DLT | Service Bus queue + dead-letter |
| App secrets (JWT, INTERNAL_TOKEN) | Secrets Manager + ECS task `secrets` block | Secret Manager + Cloud Run `value_source.secret_key_ref` | Key Vault + Container Apps secret refs |
| Tuya credentials | Secrets Manager, scoped task role | Secret Manager, scoped `secretAccessor` | Key Vault, scoped Key Vault Secrets User role |
| Service identity | One ECS task role + scoped tuya-bridge role | One `google_service_account` per service | One user-assigned managed identity per service |
| Inbound auth | API Gateway in front of ALB | Direct invocation; `allUsers` invoker | Container Apps ingress; `external` ingress per service |
| Cross-service routing | Path-based via shared ALB | Per-service `*.run.app` URLs | Per-service `*.azurecontainerapps.io` URLs |

## Porting workflow

1. **Scaffold `azure/`** as a verbatim copy of `gcp/` (mirror what PR #7
   did). Drop a banner in `azure/README.md` that says "not functional
   yet" until terraform actually works.

2. **Register the resource providers** the subscription will use:
   `Microsoft.App` (Container Apps), `Microsoft.ContainerRegistry`,
   `Microsoft.ServiceBus`, `Microsoft.KeyVault`,
   `Microsoft.DBforPostgreSQL`. Either via `az provider register
   --namespace <ns>` once per subscription, or via
   `azurerm_resource_provider_registration` resources in terraform so
   apply is self-bootstrapping (analogous to where the GCP port
   should've used `google_project_service` but didn't — same TODO).

3. **Replace `gcp/terraform/`** with Azure-provider modules:
   - `modules/container-apps/` (compute) — mirrors `gcp/terraform/modules/cloud-run/`
   - `modules/database/` — `azurerm_postgresql_flexible_server`
   - `modules/registry/` — `azurerm_container_registry` + build/push provisioner
   - Add `azurerm_servicebus_namespace` + queue + DLQ to `main.tf`
   - Add `azurerm_key_vault` + secrets in `main.tf`, scoped via role assignments
   - **Don't** copy the IAM bindings naïvely — re-derive per-service identities

4. **Write `shared/cloud/azure.py`** implementing `EventBus` and
   `SecretStore` against `azure-servicebus` and `azure-keyvault-secrets`.
   Add an `elif provider == "azure":` branch in
   `shared/cloud/__init__.py`.

5. **Update Dockerfiles** for each service in `azure/services/` to swap
   the Python deps (`boto3` or `google-cloud-*` → `azure-servicebus` +
   `azure-keyvault-secrets` + `azure-identity`).

6. **Port the cloud-specific ops scripts** (`push_images.sh`,
   `redeploy.sh`, `set_tuya_secrets.sh`) — same shape as the GCP
   versions, swap `gcloud` for `az`. `test_apis.sh` is **not** per-cloud
   — there's one unified `./test_apis.sh` at the repo root that already
   handles all three platforms via `--platform aws|gcp|azure`. Adding a
   new cloud just means adding a new case branch in the URL-resolution
   block, which reads from `<platform>/terraform/`'s
   `terraform output -json service_urls`.

7. **Real apply** on an Azure subscription. Iterate on whatever breaks.

## Gotchas the GCP port hit (and Azure probably will too)

- **Database connectivity is meaningfully different.** GCP uses the
  Cloud SQL Auth Proxy mounted as a unix socket — `DATABASE_URL` looks
  like `postgresql+asyncpg://user:pass@/db?host=/cloudsql/<conn>`.
  Azure has no equivalent; pick between (a) Container Apps environment
  with VNet integration + Private Endpoint on Postgres, or (b)
  Postgres with public access + a firewall rule for the Container
  Apps egress IPs. Either way `DATABASE_URL` becomes a regular TCP
  URL: `postgresql+asyncpg://user:pass@<host>:5432/db?ssl=require`.
  This is one of the few places where the Azure adapter has to change
  something service-code-visible (the env var format), so wire it
  through `azure/terraform/modules/container-apps/main.tf`'s
  `DATABASE_URL` construction carefully.

- **Cross-resource references force resource-block splits.** Terraform
  forbids a `for_each` instance from referencing a sibling instance of
  the same resource block ("self-referential block" error). The check
  fires at plan time, not at `terraform validate`, so you only see it
  on first real apply. The GCP module ended up with **three** Cloud
  Run resource blocks for this reason:

  1. `google_cloud_run_v2_service.main` — `automation`, `user`,
     `analytics`. Plain `for_each`, no special treatment.
  2. `google_cloud_run_v2_service.device_service` — split out because
     `analytics-service` (in `main`) needs `DEVICE_SERVICE_URL =
     device_service.uri` at create time, and a sibling-instance ref
     would have tripped the self-reference check. Tuya-bridge also
     needs this URI but gets it patched in post-create.
  3. `google_cloud_run_v2_service.tuya_bridge` — split out for a
     different reason: `lifecycle.ignore_changes = [...env]` so the
     post-create `null_resource` patch (which adds
     `DEVICE_SERVICE_URL` via `az containerapp update` /
     `gcloud run services update`) doesn't show as drift.

  **General rule for the Azure port:** any service that is the
  *target* of a cross-reference from another `for_each` instance
  **must** be in a separate resource block. Same for any service
  needing `lifecycle.ignore_changes` on env for post-create patching.
  See `gcp/terraform/modules/cloud-run/main.tf` for the full pattern.

- **Secret IAM race.** First `terraform apply` can deadlock if the
  Container App tries to start before its identity has been granted
  read access on the Key Vault secret. Mitigate by putting the role
  assignments **inside the compute module** and adding
  `depends_on = [<role assignments>]` on the Container App resources
  themselves — see `gcp/terraform/modules/cloud-run/main.tf`'s
  `app_secrets` + `depends_on` for the analogue.

- **Secrets are loaded at container start, not per-request.** Updating
  a Key Vault secret won't recycle live container revisions; you have
  to force new revisions. The GCP rotation runbook in `gcp/README.md`
  is the template — adapt the `gcloud` commands to `az`.

- **`terraform destroy` ordering needs help in two places.** Both
  surfaced on the first real GCP teardown:

  1. *Compute → DB connection drain.* The Container App / Cloud Run
     delete API returns success before all sessions on the Postgres
     side are actually closed. We tried three passive approaches and
     all of them failed on real teardowns:
     - `time_sleep` alone — even 180s wasn't enough.
     - Aggressive `tcp_keepalives_idle/interval/count` via
       `database_flags`, so Postgres reaps dead sessions in ~90s
       instead of the default 2 hours.
     - Both combined.

     The sessions Cloud Run leaves behind aren't always "dead" in a
     way TCP keepalives detect — sometimes the kernel never sends
     RST/FIN. The only reliable fix is **active** session
     termination: restart the SQL instance immediately before the DB
     drop. A restart kills every session unconditionally and takes
     ~30s. By the time it fires, the compute layer is already gone,
     so nothing reconnects. See
     `null_resource.terminate_db_connections` in
     `gcp/terraform/modules/database/main.tf` (a destroy-time
     `local-exec` that runs `gcloud sql instances restart`). For
     Azure, the equivalent is `az postgres flexible-server restart`.

     A short `time_sleep` (30s) between compute teardown and the
     restart is still useful as a buffer in case the platform's
     container cleanup lags the API "deleted" signal. The
     `tcp_keepalives_*` flags are also worth keeping — they don't fix
     this scenario but they help reap dead sessions in normal
     operation (dev-machine disconnects, network blips).

  2. *DB user owns DB objects.* `google_sql_database` and
     `google_sql_user` (or their Azure equivalents) are siblings under
     the instance and Terraform destroys them in parallel. Postgres
     refuses to drop a role that still owns schema objects, so
     whichever finishes first determines whether the role-drop sees
     an empty database. Add `depends_on = [<db_user>]` on the
     database resource to force user → database create order, which
     reverses to database → user on destroy. See
     `gcp/terraform/modules/database/main.tf`.

- **Build context = repo root.** Service Dockerfiles need to `COPY
  shared/` into the image, so every `docker build` must run from the
  repo root with `-f azure/services/<svc>/Dockerfile`. Otherwise
  `from shared.cloud import event_bus` fails at startup. The
  registry module's null_resource is the source of truth for this
  pattern — copy `gcp/terraform/modules/registry/main.tf`'s shape.

- **Source hash must include `shared/`.** When the abstraction layer
  changes, every service image needs rebuilding. The `src_hash`
  trigger on the build null_resource should fold in
  `fileset("${path.root}/../../shared", "**/*.py")` the way both
  cloud-specific modules already do.

- **Container Apps min-replicas costs real money** the same way Cloud
  Run does. Default `min_instances = 0` for demos; bump to 2 only
  when actively showing the load-balancer behavior.

## Verifying the port

Once Azure is provisioned, `./test_apis.sh --platform azure` should
pass against the new per-service URLs. If it does, the port is done
end-to-end. If a specific service fails, it's almost always one of:

- adapter wired wrong (`CLOUD_PROVIDER` env var, or the protocol
  contract slipped)
- IAM grant missing on the runtime identity
- secret name mismatch between terraform and the service's env

The shape of the AWS and GCP deployments is identical from the
service's perspective — Azure should land in the same place.
