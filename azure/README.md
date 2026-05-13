# Azure Smart Home Hub — Container Apps / Postgres Flexible / Service Bus

Azure port of the AWS-based platform under `aws/`. Same service code on
all three clouds — the cloud-specific SDK calls (event bus, secret store)
sit behind `shared/cloud/`, which picks an adapter at runtime from
`CLOUD_PROVIDER`.

## What this folder deploys

| Concern | AWS | GCP | Azure |
|---|---|---|---|
| Compute | ECS Fargate behind ALB | Cloud Run v2 | Container Apps, per-service `*.azurecontainerapps.io` URLs |
| Container images | ECR + `docker push` | Artifact Registry + `docker push` | Azure Container Registry + `docker push` |
| Database | RDS Postgres in private subnets | Cloud SQL Postgres via Auth Proxy | Azure Database for PostgreSQL Flexible Server, public endpoint + Azure-services firewall rule |
| Event bus | SQS queue + DLQ + redrive | Pub/Sub topic + subscription + dead-letter topic | Service Bus queue + DLQ via `forward_dead_lettered_messages_to` |
| Secrets (Tuya) | Secrets Manager, scoped task role | Secret Manager, scoped `secretAccessor` on tuya-bridge SA | Key Vault, scoped `Key Vault Secrets User` on tuya-bridge identity |
| Secrets (JWT + INTERNAL_TOKEN) | Secrets Manager via task definition `secrets` block | Secret Manager via Cloud Run `value_source.secret_key_ref` | Key Vault via Container App `secret { key_vault_secret_id = ... }` blocks; all five identities granted `Key Vault Secrets User` |
| Service identity | One ECS task role + scoped tuya-bridge role | One `google_service_account` per service | One `azurerm_user_assigned_identity` per service |
| Inbound auth | API Gateway in front of ALB | Direct invocation; `allUsers` invoker | Direct invocation; `external_enabled = true` ingress per service. App-level `INTERNAL_TOKEN` gates inter-service calls |

No VPC / networking module — Container Apps is fully managed, and
Postgres uses public endpoint + the "allow Azure services" firewall
rule (`0.0.0.0`/`0.0.0.0`) so Container Apps reaches it directly. A
VNet-integrated Container Apps environment with Private Endpoint
Postgres would be the production shape; this topology is the demo
shape.

## Cross-service URLs — how the cycle is broken

The container-apps module ends up with **three** `azurerm_container_app`
resource blocks instead of one `for_each` over all five services:

1. `azurerm_container_app.main` (automation, user, analytics) —
   plain `for_each`.
2. `azurerm_container_app.device_service` — split out because
   Terraform forbids a `for_each` instance from referencing a sibling
   instance ("self-referential block" at plan time). `analytics-service`
   needs `DEVICE_SERVICE_URL = device_service.ingress[0].fqdn` at create
   time, and the post-create `null_resource` patch onto `tuya-bridge`
   reads the same FQDN.
3. `azurerm_container_app.tuya_bridge` — split out for a different
   reason: `lifecycle.ignore_changes = [template[0].container[0].env]`
   so the post-create patch that injects `DEVICE_SERVICE_URL` doesn't
   show as Terraform drift on subsequent plans.

The cycle itself is broken by:

- `device-service` references `tuya_bridge.ingress[0].fqdn` at create
  time (`TUYA_BRIDGE_URL` env var).
- `tuya-bridge` receives `DEVICE_SERVICE_URL` *after* `device-service`
  exists, via a `null_resource` running
  `az containerapp update --set-env-vars`.
- `lifecycle.ignore_changes` on `tuya-bridge`'s env absorbs the patch.

**Trade-off:** `tuya-bridge`'s env list is effectively "managed by
null_resource" going forward. Terraform-declared changes to its env
(e.g. rotating `JWT_SECRET` via `terraform taint
random_password.jwt_secret`) won't auto-apply — they need
`terraform taint module.container_apps.null_resource.patch_tuya_bridge_url`
to re-trigger the patch, or a manual `az containerapp update`. The
other four services have normal Terraform env management.

Image rebuilds and other Terraform-managed updates to `tuya-bridge`
*are* handled: `replace_triggered_by` on the null_resource re-runs
the patch whenever Terraform updates `tuya-bridge` for any reason,
so `DEVICE_SERVICE_URL` survives image bumps and resource-limit
changes. Manual `az containerapp update --image=...` outside of
Terraform bypasses this — pass `--set-env-vars DEVICE_SERVICE_URL=...`
explicitly when doing that, or follow with a `terraform apply` to
re-run the patch.

All five services have `external_enabled = true` ingress, matching the
AWS setup where the ALB is public. App-level `INTERNAL_TOKEN`
(plumbed via Key Vault → Container App secret refs) is the real auth
boundary for inter-service calls.

## Rotating `JWT_SECRET` / `INTERNAL_TOKEN`

The secrets are read by Container Apps *at container start* (the
`secret { key_vault_secret_id = ... }` block resolves at revision
creation time, not per request). Creating a new Key Vault secret
version doesn't recycle running containers — they keep serving the
old value cached at startup. A full rotation is two steps:

```bash
# 1. Bump the secret values (new random_password -> new Key Vault version)
terraform taint random_password.jwt_secret
terraform taint random_password.internal_token
terraform apply

# 2. Force a new revision per service so the new values get fetched.
#    For the three non-tuya non-device services, tainting the Container App
#    resources is enough. For device-service and tuya-bridge, also taint
#    the null_resource so the DEVICE_SERVICE_URL patch reapplies.
for svc in automation-service user-service analytics-service; do
  terraform taint 'module.container_apps.azurerm_container_app.main["'"$svc"'"]'
done
terraform taint module.container_apps.azurerm_container_app.device_service
terraform taint module.container_apps.azurerm_container_app.tuya_bridge
terraform taint module.container_apps.null_resource.patch_tuya_bridge_url
terraform apply
```

## Operations scripts

- `./azure/push_images.sh` — `docker build` + `docker push` each service
  image to Azure Container Registry. Uses the repo-root build context
  so `shared/` gets copied in, matching the Terraform `null_resource`
  behavior.
- `./azure/redeploy.sh` — forces a new Container Apps revision per
  service via `az containerapp update --image=...`. Re-runs the
  `tuya-bridge` `DEVICE_SERVICE_URL` patch as part of the same flow.
- `./azure/set_tuya_secrets.sh` — adds a new version of the
  `tuya-credentials` Key Vault secret. tuya-bridge reads at container
  start, so a rollout requires forcing a new tuya-bridge revision
  (printed at the end of the script).
- `./azure/test_apis.sh` — same flag/operation surface as the AWS
  and GCP versions; resolves per-service URLs from
  `terraform output -json service_urls` and routes each call to the
  matching `*.azurecontainerapps.io` based on the `/api/v1/<service>/`
  path segment.

## Cost note

The default `min_instances = 0` keeps the burn negligible when idle —
Container Apps scales to zero, ACR Basic is ~$5/month, Service Bus
Standard is ~$10/month, and the Postgres B1ms burstable is ~$15/month.
A stack left running idle is roughly a dollar a day; `min_instances`
bumped above zero for an active load-balancer demo is more, but still
modest. `terraform destroy` between demos is cheaper still.

## Prerequisites

On the machine running `terraform apply` and the ops scripts:

- `terraform` ≥ 1.0, `docker`, `az` (Azure CLI), `curl`, `jq`
- `bash` ≥ 4 (for `azure/test_apis.sh`'s per-service URL dispatch).
  macOS still ships 3.2 — install via `brew install bash` and invoke
  the script as `/opt/homebrew/bin/bash ./azure/test_apis.sh`.
- `az` authenticated to your account with subscription access:
  ```bash
  az login
  az account set --subscription <your-subscription-id>
  ```
  The same credential covers both the azurerm Terraform provider (via
  Azure CLI auth) and the `az`-based ops scripts.

The principal running `terraform apply` needs **Owner** or **User
Access Administrator** at subscription scope — plain Contributor is
not enough because the configuration creates `azurerm_role_assignment`
resources for the per-service managed identities.

## Running it

```bash
cd azure/terraform
cp terraform.tfvars.example terraform.tfvars
# Fill in azure_subscription_id, db_password, and (if using Tuya)
# tuya_client_id / tuya_client_secret. Postgres admin password must
# satisfy Azure complexity rules: 8-128 chars, 3 of {upper, lower,
# digit, special}. Avoid URL-unsafe chars (@:/?#%) — the password is
# interpolated raw into DATABASE_URL.

terraform init
terraform apply
```

After apply, `terraform output service_urls` returns the five public
service URLs. Each service is reached directly at its own
`*.azurecontainerapps.io` hostname — there is no shared API Gateway
in this deployment.

### Subscription-specific gotchas

- **`LocationIsOfferRestricted` for Postgres.** Student / sponsorship
  / free-tier subscriptions often refuse Flexible Server provisioning
  in some regions (commonly `eastus`). Set `db_location = "eastus2"`
  (or another working region) in `terraform.tfvars` to put Postgres
  alone in a different region while the rest of the stack stays in
  `azure_location`. Container Apps in the primary region make
  cross-region calls to Postgres — adds a few ms of latency and
  modest egress, but works.
- **Pre-registered resource providers.** If `Microsoft.KeyVault`,
  `Microsoft.ContainerRegistry`, etc. are already registered on the
  subscription, `azurerm_resource_provider_registration` errors with
  "already exists - to be managed via Terraform this resource needs to
  be imported into the State." `terraform import` each one:
  ```bash
  SUB=$(az account show --query id -o tsv)
  for NS in Microsoft.KeyVault Microsoft.ContainerRegistry Microsoft.OperationalInsights Microsoft.ManagedIdentity; do
    terraform import "azurerm_resource_provider_registration.required[\"$NS\"]" "/subscriptions/$SUB/providers/$NS"
  done
  ```
- **Failed Postgres creates hold the name for ~24h.** If a first apply
  fails at Postgres creation, the resource name lingers in Azure's
  backend even though the resource doesn't show up in the API. Either
  wait or bump the postgres name (e.g. add a version suffix to the
  `name = "${var.name_prefix}-pg-${var.unique_suffix}"` line in
  `modules/database/main.tf`).
