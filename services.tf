# =============================================================================
# Single source of truth: the five microservices deployed to AWS, GCP, Azure.
# =============================================================================
# This file is symlinked into each cloud's terraform/ directory as
# `services.tf`. Terraform auto-loads every `*.tf` in the working
# directory, so `terraform plan` / `terraform apply` in any of
# `aws/terraform/`, `gcp/terraform/`, `azure/terraform/` picks up the
# `variable "services"` declaration (and its default) without any
# extra flag.
#
# Symlinks:
#   aws/terraform/services.tf   -> ../../services.tf
#   gcp/terraform/services.tf   -> ../../services.tf
#   azure/terraform/services.tf -> ../../services.tf
#
# Adding or removing a service is one edit here.
#
# Only the truly cross-cloud fields live in the default. Per-cloud knobs
# (ECS cpu/memory shares, Cloud Run vCPU strings, Container Apps cpu
# floats, ALB listener-rule priorities) come from each cloud's
# `local.<cloud>_overrides` map in its main.tf and are merged in there —
# different units / different keys, so collapsing them into one shape
# would obscure more than it would share.
#
# `port` reminder: the listening port is also baked into each service's
# Dockerfile (`EXPOSE` and `--port` in `CMD`). Changing it here without
# updating the Dockerfile means the container won't bind to what the
# load balancer is forwarding to.

variable "services" {
  description = "Canonical cross-cloud service catalog. Single source of truth for the five microservices (device, automation, user, analytics, tuya-bridge). Per-cloud sizing/priority is layered on via local.<cloud>_overrides in each cloud's main.tf."

  type = map(object({
    port        = number
    health_path = string
    owner       = string
  }))

  default = {
    device-service     = { port = 8001, health_path = "/health", owner = "Member1" }
    automation-service = { port = 8002, health_path = "/health", owner = "Member2" }
    user-service       = { port = 8003, health_path = "/health", owner = "Member3" }
    analytics-service  = { port = 8004, health_path = "/health", owner = "Member4" }
    tuya-bridge        = { port = 8005, health_path = "/health", owner = "Platform" }
  }
}
