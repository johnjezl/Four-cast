# Per-service module inputs. One instance per entry in the shared services
# map. Everything that scales 1:1 with the service catalog lives here; the
# cluster, ALB, IAM roles, and shared secrets stay in the parent ecs module.

variable "service_name" {
  description = "Canonical service name (the key from the shared services map)."
  type        = string
}

variable "port" {
  description = "Container port. Must match what the Dockerfile EXPOSEs / CMD binds — the load balancer forwards here."
  type        = number
}

variable "health_path" {
  description = "HTTP path the ALB health check probes."
  type        = string
}

variable "cpu" {
  description = "ECS task CPU units (per-cloud knob from local.aws_overrides)."
  type        = number
}

variable "memory" {
  description = "ECS task memory in MiB."
  type        = number
}

variable "priority" {
  description = "ALB listener-rule priority. Explicit so adding a service can't silently renumber existing rules."
  type        = number
}

variable "desired_count" {
  description = "Number of task replicas (2+ to demo the load balancer)."
  type        = number
}

variable "name_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "log_level" {
  type = string
}

variable "common_tags" {
  type = map(string)
}

# ---------------------------------------------------------------------------
# Wiring from the parent (cluster / ALB / IAM)
# ---------------------------------------------------------------------------
variable "cluster_id" {
  type = string
}

variable "alb_listener_arn" {
  type = string
}

variable "alb_dns_name" {
  description = "Used both for the ALB target group and for the cross-service env vars baked into the task definition."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "ecs_tasks_security_group_id" {
  type = string
}

variable "execution_role_arn" {
  type = string
}

variable "task_role_arn" {
  description = "Task role for this service. Parent picks the scoped tuya-bridge role for tuya-bridge and the generic task role for everyone else."
  type        = string
}

variable "aws_region" {
  description = "Passed in so the build/push provisioner doesn't need its own data source."
  type        = string
}

# ---------------------------------------------------------------------------
# App config (DB, secrets, event bus, Tuya)
# ---------------------------------------------------------------------------
variable "db_endpoint" {
  type = string
}

variable "db_name" {
  type = string
}

variable "db_username" {
  type      = string
  sensitive = true
}

variable "db_password" {
  description = "Database password. Interpolated into DATABASE_URL inside the rendered container definition. Terraform marks it sensitive in plan output, but the rendered task definition stores DATABASE_URL in plaintext on the AWS side (visible via `aws ecs describe-task-definition`). Pre-existing situation — not refactor-introduced. For real deployments, move to Secrets Manager + a `secrets` block."
  type        = string
  sensitive   = true
}

variable "device_events_queue" {
  description = "SQS queue URL for device events. Same value on every service (each task selects the env var it cares about)."
  type        = string
}

variable "jwt_secret_arn" {
  description = "Secrets Manager ARN for the JWT signing secret. Injected via the task definition's `secrets` block; execution role needs GetSecretValue on it (granted in the cluster module)."
  type        = string
}

variable "internal_token_arn" {
  description = "Secrets Manager ARN for the service-to-service auth token."
  type        = string
}

variable "tuya_secret_name" {
  description = "Name of the Secrets Manager secret holding Tuya credentials. Used by the service via SECRET_NAME env."
  type        = string
}

variable "tuya_device_ids" {
  description = "Optional comma-separated allowlist of Tuya device IDs."
  type        = string
}
