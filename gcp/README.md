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
| Service identity | One ECS task role + scoped tuya-bridge role | One `google_service_account` per service |
| Inbound auth | API Gateway in front of ALB | Direct invocation; `allUsers` invoker except tuya-bridge (device-service SA only) |

No VPC / networking module — Cloud Run is fully managed and reaches
Cloud SQL through the Auth Proxy's unix socket, so a Serverless VPC
Connector isn't needed for this topology.

## Cross-service URLs — how the cycle is broken

`device-service` ↔ `tuya-bridge` need each other's `*.run.app` URI,
which would form a Terraform reference cycle if both were declared
inside the same `for_each`. The module breaks it by:

1. Pulling `tuya-bridge` out of the `for_each` into its own
   `google_cloud_run_v2_service` resource. `device-service` references
   that resource's `.uri` at create time (`TUYA_BRIDGE_URL` env var).
2. Patching `DEVICE_SERVICE_URL` onto `tuya-bridge` *after* both
   services exist via a `null_resource` that runs
   `gcloud run services update --update-env-vars`.
3. Setting `lifecycle.ignore_changes = [...env]` on the `tuya-bridge`
   resource so the post-create patch isn't seen as drift on subsequent
   plans.

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

## Still TODO

- **`JWT_SECRET` / `INTERNAL_TOKEN`** are plain Cloud Run env vars; AWS
  pulls them from Secrets Manager via the ECS task definition's
  `secrets` block. The GCP equivalent (Secret Manager + Cloud Run
  secret env volumes) is mechanical but not done in this PR.
- `push_images.sh`, `redeploy.sh`, `set_tuya_secrets.sh`, and
  `test_apis.sh` are still the AWS scripts — left as-is for now.

## Cost note

The default `min_instances = 2` keeps two warm containers per service —
five services × two containers × 1 vCPU = ten always-allocated vCPUs.
That's well above the Cloud Run free tier (~240k vCPU-seconds/month),
so a stack left running for a week is not free. Set `min_instances = 0`
in `terraform.tfvars` if you don't need the load-balancer demo, and
`terraform destroy` between demos.

## Running it

```bash
cd gcp/terraform
cp terraform.tfvars.example terraform.tfvars
# Fill in gcp_project_id, db_password, and (if using Tuya)
# tuya_client_id / tuya_client_secret.

gcloud auth application-default login
gcloud config set project <your-project-id>

terraform init
terraform apply
```

The build-and-push step needs `docker` + `gcloud` on the machine running
apply (same shape as the AWS module needing `docker` + `aws`).

After apply, `terraform output service_urls` returns the five public
service URLs. Each service is reached directly at its own `*.run.app`
hostname — there is no shared API Gateway in this deployment.
