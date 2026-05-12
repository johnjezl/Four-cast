# GCP Smart Home Hub — Scaffold Only

> ⚠️ **NOT YET FUNCTIONAL — DO NOT RUN `terraform apply` AGAINST THIS FOLDER.**
>
> This directory is a verbatim copy of `aws/` created to give the GCP
> port a starting point. Nothing here is adapted to Google Cloud yet:
>
> - `terraform/` still declares the **AWS provider** and uses `aws_*`
>   resources. `terraform init` will pull the AWS provider; `apply`
>   would (a) fail to authenticate against GCP, and (b) if it somehow
>   reached AWS, would collide with the AWS deployment because both
>   trees share `name_prefix = "smarthome-${var.environment}"`.
> - `services/*/main.py` still imports `boto3` and calls AWS APIs
>   (SQS, Secrets Manager).
> - `push_images.sh`, `redeploy.sh`, `set_tuya_secrets.sh` still invoke
>   the `aws` CLI against ECR / ECS / Secrets Manager.
> - `test_apis.sh` works against whatever deployment is reachable at
>   the API Gateway URL it reads from `gcp/terraform/`'s output — and
>   that output doesn't exist yet.
>
> The GCP adaptation will land in follow-up PRs. Once both clouds
> work, anything that genuinely stays identical between `aws/` and
> `gcp/` will move into a shared top-level location.
