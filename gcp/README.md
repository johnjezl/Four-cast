# GCP Smart Home Hub — Cloud Run / Cloud SQL / Pub/Sub

GCP port of the AWS-based platform under `aws/`. Same service code on
both clouds — the cloud-specific SDK calls (event bus, secret store)
sit behind `shared/cloud/`, which picks an adapter at runtime from
`CLOUD_PROVIDER`.

## What this folder deploys

| Concern | AWS | GCP |
|---|---|---|
| Compute | ECS Fargate behind ALB | Cloud Run v2, per-service `*.run.app` URLs |
| Container images | ECR + `docker push` | Artifact Registry + `docker push` |
| Database | RDS Postgres in private subnets | Cloud SQL Postgres, via the Cloud SQL Auth Proxy |
| Event bus | SQS queue + DLQ + redrive | Pub/Sub topic + subscription + dead-letter topic |
| Secrets (Tuya) | Secrets Manager, scoped task role | Secret Manager, scoped `secretAccessor` on tuya-bridge SA |
| Secrets (JWT + INTERNAL_TOKEN) | Secrets Manager via task definition `secrets` block | Secret Manager via Cloud Run `env.value_source.secret_key_ref`; all five SAs granted `secretAccessor` |
| Service identity | One ECS task role + scoped tuya-bridge role | One `google_service_account` per service |
| Inbound auth | API Gateway in front of ALB | Direct invocation; `allUsers` invoker on every service. App-level `INTERNAL_TOKEN` gates inter-service calls |

No VPC / networking module — Cloud Run is fully managed and reaches
Cloud SQL through the Auth Proxy's unix socket, so a Serverless VPC
Connector isn't needed for this topology.

## Cross-service URLs — how the cycle is broken

The cloud-run module ends up with **three** `google_cloud_run_v2_service`
resource blocks instead of one `for_each` over all five services:

1. `google_cloud_run_v2_service.main` (automation, user, analytics) —
   plain `for_each`.
2. `google_cloud_run_v2_service.device_service` — split out because
   Terraform forbids a `for_each` instance from referencing a sibling
   instance ("self-referential block" at plan time). `analytics-service`
   needs `DEVICE_SERVICE_URL = device_service.uri` at create time, and
   the post-create `null_resource` patch onto `tuya-bridge` reads the
   same URI.
3. `google_cloud_run_v2_service.tuya_bridge` — split out for a
   different reason: `lifecycle.ignore_changes = [...env]` so the
   post-create patch that injects `DEVICE_SERVICE_URL` doesn't show as
   Terraform drift on subsequent plans.

The cycle itself is broken by:

- `device-service` references `tuya_bridge.uri` at create time
  (`TUYA_BRIDGE_URL` env var).
- `tuya-bridge` receives `DEVICE_SERVICE_URL` *after* `device-service`
  exists, via a `null_resource` running
  `gcloud run services update --update-env-vars`.
- `lifecycle.ignore_changes` on `tuya-bridge`'s env absorbs the patch.

**Trade-off:** `tuya-bridge`'s env list is effectively "managed by
null_resource" going forward. Terraform-declared changes to its env
(e.g. rotating `JWT_SECRET` via `terraform taint
random_password.jwt_secret`) won't auto-apply — they need
`terraform taint null_resource.patch_tuya_bridge_url` to re-trigger
the patch, or a manual `gcloud run services update`. The other four
services have normal Terraform env management.

Image rebuilds and other Terraform-managed updates to `tuya-bridge`
*are* handled: `replace_triggered_by` on the null_resource re-runs
the patch whenever Terraform updates `tuya-bridge` for any reason,
so `DEVICE_SERVICE_URL` survives image bumps and resource-limit
changes. Manual `gcloud run services update --image=...` outside of
Terraform bypasses this — pass `--update-env-vars=DEVICE_SERVICE_URL=...`
explicitly when doing that, or follow with a `terraform apply` to
re-run the patch.

`tuya-bridge` is also reachable via `allUsers` invoker (same as the
other services). PR #9's IAM restriction to the `device-service` SA
was reverted in this PR — invoking it from `device-service` over
Cloud Run IAM would require minting Google ID tokens, which is a
service-code change we deferred. App-level `INTERNAL_TOKEN` remains
the real auth boundary, matching the AWS setup where the ALB is
public.

## Rotating `JWT_SECRET` / `INTERNAL_TOKEN`

The secrets are read by Cloud Run *at container start* (via
`value_source.secret_key_ref` pointing at version `"latest"`).
Creating a new secret version doesn't recycle running containers —
they keep serving the old value cached at startup. A full rotation
is two steps:

```bash
# 1. Bump the secret values (new random_password -> new secret version)
terraform taint random_password.jwt_secret
terraform taint random_password.internal_token
terraform apply

# 2. Force a new revision per service so the new values get fetched.
#    For the four main services, tainting the Cloud Run resources is
#    enough. For tuya-bridge, also taint the null_resource so the
#    DEVICE_SERVICE_URL patch reapplies on the new revision.
for svc in device-service automation-service user-service analytics-service; do
  terraform taint 'module.cloud_run.google_cloud_run_v2_service.main["'"$svc"'"]'
done
terraform taint module.cloud_run.google_cloud_run_v2_service.tuya_bridge
terraform taint module.cloud_run.null_resource.patch_tuya_bridge_url
terraform apply
```

## Operations scripts

- `./gcp/push_images.sh` — `docker build` + `docker push` each service
  image to Artifact Registry. Uses the repo-root build context so
  `shared/` gets copied in, matching the Terraform `null_resource`
  behavior.
- `./gcp/redeploy.sh` — forces a new Cloud Run revision per service via
  `gcloud run services update --image=...`. After this, run
  `terraform apply` so the `tuya-bridge` `DEVICE_SERVICE_URL` patch
  re-fires against the new revision.
- `./gcp/set_tuya_secrets.sh` — adds a new version to the Tuya
  Secret Manager secret. Cloud Run reads at container start, so a
  rollout requires forcing a new `tuya-bridge` revision (printed at the
  end of the script).
- `./test_apis.sh --platform gcp` — repo-root unified test script; resolves
  per-service URLs from `gcp/terraform/`'s `terraform output -json
  service_urls` and routes each call to the matching `*.run.app` based on
  the `/api/v1/<service>/` path segment. Also works against AWS and Azure
  via `--platform aws` / `--platform azure`, or against a captured URL
  snapshot via `--urls-file PATH`.

## Cost note

The default `min_instances = 2` keeps two warm containers per service —
five services × two containers × 1 vCPU = ten always-allocated vCPUs.
That's well above the Cloud Run free tier (~240k vCPU-seconds/month),
so a stack left running for a week is not free. Set `min_instances = 0`
in `terraform.tfvars` if you don't need the load-balancer demo, and
`terraform destroy` between demos.

## Prerequisites

On the machine running `terraform apply` and the ops scripts:

- `terraform` ≥ 1.0, `docker`, `gcloud`, `curl`, `jq`
- `bash` ≥ 4 (for `test_apis.sh`'s per-service URL dispatch).
  macOS still ships 3.2 — install via `brew install bash` and invoke
  the script as `/opt/homebrew/bin/bash ./test_apis.sh --platform gcp`.
- gcloud authenticated to your account with project access:
  ```bash
  gcloud auth login
  gcloud auth application-default login
  gcloud config set project <your-project-id>
  ```
  `auth login` is for `gcloud` CLI commands (`push_images.sh`,
  `redeploy.sh`, `set_tuya_secrets.sh`). `application-default login`
  is for Terraform's google provider.

## Running it

```bash
cd gcp/terraform
cp terraform.tfvars.example terraform.tfvars
# Fill in gcp_project_id, db_password, and (if using Tuya)
# tuya_client_id / tuya_client_secret.

terraform init
terraform apply
```

After apply, `terraform output service_urls` returns the five public
service URLs. Each service is reached directly at its own `*.run.app`
hostname — there is no shared API Gateway in this deployment.
