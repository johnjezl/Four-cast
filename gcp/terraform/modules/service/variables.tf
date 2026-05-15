# GCP per-service module inputs.
#
# The same module body is instantiated three ways from the parent:
#   - module.device_service     (singleton, takes tuya_bridge_url)
#   - module.service[*]         (for_each over the middle three; take device_service_url)
#   - module.tuya_bridge        (singleton, ignore_env_changes = true)
#
# The split is forced by Terraform's "self-referential block" check —
# a `for_each` instance can't reference another instance of the same
# resource/module at create time. See docs/porting-guide.md for the
# full explanation.

variable "service_name" {
  description = "Canonical service name (the key from the shared services map)."
  type        = string
}

variable "port" {
  description = "Container port. Must match the Dockerfile's EXPOSE / CMD --port."
  type        = number
}

variable "cpu" {
  description = "Cloud Run vCPU limit, e.g. \"1\"."
  type        = string
}

variable "memory" {
  description = "Cloud Run memory limit, e.g. \"512Mi\"."
  type        = string
}

variable "image_url" {
  description = "Fully qualified Artifact Registry image URL (with :latest tag)."
  type        = string
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

variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "min_instances" {
  type = number
}

variable "max_instances" {
  type = number
}

# ---------------------------------------------------------------------------
# Database (Cloud SQL Auth Proxy mount)
# ---------------------------------------------------------------------------
variable "db_connection_name" {
  description = "Cloud SQL connection name (project:region:instance)."
  type        = string
}

variable "db_name" {
  type = string
}

variable "db_username" {
  type      = string
  sensitive = true
}

variable "db_password" {
  description = "Database password. Interpolated into DATABASE_URL inside the rendered env list. Terraform marks it sensitive in plan output, but Cloud Run stores DATABASE_URL in plaintext on the service revision (visible via `gcloud run services describe`). Pre-existing situation — not refactor-introduced. For real deployments, move the credential to Secret Manager + a `value_source.secret_key_ref` env entry."
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Secrets + event bus + Tuya
# ---------------------------------------------------------------------------
variable "jwt_secret_id" {
  description = "Short ID of the JWT secret in Secret Manager. Fetched by Cloud Run at container start via value_source.secret_key_ref."
  type        = string
}

variable "internal_token_id" {
  description = "Short ID of the internal-token secret in Secret Manager."
  type        = string
}

variable "event_topic" {
  description = "Pub/Sub topic short name. Same value on every service (each one reads the env var it cares about)."
  type        = string
}

variable "event_subscription" {
  description = "Pub/Sub subscription short name."
  type        = string
}

variable "tuya_secret_name" {
  description = "Short name of the Tuya credentials secret in Secret Manager. Used by tuya-bridge via SECRET_NAME env."
  type        = string
}

variable "tuya_device_ids" {
  description = "Optional comma-separated allowlist of Tuya device IDs."
  type        = string
}

# ---------------------------------------------------------------------------
# Cross-service URLs — empty unless the parent passes them in
# ---------------------------------------------------------------------------
# Each call site only sets the URL its service actually needs:
#   - device_service takes tuya_bridge_url
#   - analytics + automation take device_service_url
#   - user-service takes neither
#   - tuya-bridge gets DEVICE_SERVICE_URL patched in post-create (left
#     empty here; see null_resource.patch_tuya_bridge_url in parent)
#
# Templatefile uses these to conditionally inject the corresponding env
# var into the rendered list. Empty string = not added.
variable "device_service_url" {
  description = "URL of device-service. Set only on services that call it."
  type        = string
  default     = ""
}

variable "tuya_bridge_url" {
  description = "URL of tuya-bridge. Set only on services that call it (device-service)."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Lifecycle / drift handling
# ---------------------------------------------------------------------------
variable "ignore_env_changes" {
  description = "When true, ignore drift on template[0].containers[0].env. Used for tuya-bridge whose DEVICE_SERVICE_URL is patched in by a null_resource after create. Implemented as a count switch between two resource blocks because Terraform's lifecycle meta-argument can't be conditional."
  type        = bool
  default     = false
}
