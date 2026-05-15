# Service Comparison of Cloud-Based Smart Home Hub

A portable microservice control plane for IoT devices, deployed to **AWS**, **GCP**, and **Azure** with the same Python service code on all three. Cloud-specific SDK calls (event bus, secret store) sit behind a runtime-selected adapter in `shared/cloud/`; the cloud is picked from the `CLOUD_PROVIDER` env var.

## Repo layout

```
aws/      AWS port — ECS Fargate, RDS, SQS, Secrets Manager, API Gateway + ALB
gcp/      GCP port — Cloud Run v2, Cloud SQL, Pub/Sub, Secret Manager
azure/    Azure port — Container Apps, Postgres Flexible Server, Service Bus, Key Vault
shared/   Cloud-agnostic service code + per-cloud adapters (aws.py / gcp.py / azure.py)
docs/     Project documents
test_apis.sh  End-to-end test sweep; routes per-cloud via `--platform {aws,gcp,azure}`
```

## Services

Five microservices, identical code on all three clouds:

- **device-service** — system of record for device shadow (desired/reported state) in Postgres
- **tuya-bridge** — only service that knows Tuya exists; pulls commands and pushes reported state
- **user-service** — auth/identity; issues JWTs verified locally by other services
- **automation-service** — "if X then Y" rule engine
- **analytics-service** — event-bus consumer; read-only aggregates

## Per-cloud setup

Each cloud folder has its own README with the full deploy story:

- [`aws/README.md`](aws/README.md)
- [`gcp/README.md`](gcp/README.md)
- [`azure/README.md`](azure/README.md)

Typical flow per cloud:

```bash
cd <cloud>/terraform
cp terraform.tfvars.example terraform.tfvars   # fill in project id, db password, Tuya creds
terraform init && terraform apply

cd ../..
./<cloud>/push_images.sh                       # build + push images
./<cloud>/redeploy.sh                          # force new revisions
./test_apis.sh --platform <cloud>              # end-to-end test sweep
```

**Give the stack ~60–120 seconds after `terraform apply` exits before running the test sweep.** `terraform apply` returns once each compute resource reports Ready, but several things finish settling after that: load-balancer / ingress routing propagation, IAM-binding propagation (Pub/Sub publishers, Service Bus roles, etc.), the post-create `null_resource` that patches `DEVICE_SERVICE_URL` onto `tuya-bridge` (which itself triggers a new revision rollout), and the first Cloud SQL Auth Proxy / Postgres Flexible Server handshake from a fresh container. Hit `/health` on each service URL a few times until all return `200` before running `test_apis.sh`; otherwise early calls may 404 / 403 / 503 on a stack that's still becoming reachable. 

## API

See [`docs/api-guide.md`](docs/api-guide.md) for the public API surface across services.

## Prerequisites

- `terraform` ≥ 1.0, `docker`, `curl`, `jq`, `bash` ≥ 4
- Cloud CLI for whichever cloud(s) you target: `aws`, `gcloud`, `az` — each authenticated to an account with admin on the target project/subscription
- A Tuya IoT Platform project (client id + secret) if you want real device control; the stack deploys fine without it, just `tuya-bridge` calls will 401 upstream
