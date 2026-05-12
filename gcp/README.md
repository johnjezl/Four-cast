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

## Still TODO

- **`JWT_SECRET` / `INTERNAL_TOKEN`** are plain Cloud Run env vars; AWS
  pulls them from Secrets Manager via the ECS task definition's
  `secrets` block. The GCP equivalent (Secret Manager + Cloud Run
  secret env volumes) is mechanical but not done in this PR.
- **Cross-service URLs.** `TUYA_BRIDGE_URL` and `DEVICE_SERVICE_URL`
  aren't set on Cloud Run yet — `device-service` ↔ `tuya-bridge`
  Cloud Run URIs form a Terraform reference cycle that needs a
  post-create gcloud step or a one-direction breaker. Until then,
  command dispatch and state reporting between the two services
  doesn't work. Health, login, and event ingest all do.
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
