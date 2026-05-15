# Azure per-service sub-module inputs.
#
# Instantiated three ways from the parent (modules/container-apps/main.tf):
#   - tuya_bridge   — singleton, ignore_env_changes = true (DEVICE_SERVICE_URL
#                     is patched in post-create by a null_resource at
#                     parent scope)
#   - device_service — singleton, takes tuya_bridge_url
#   - service[*]    — for_each over [automation, user, analytics],
#                     takes device_service_url
#
# Same self-referential-block constraint as GCP.

variable "service_name" {
  description = "Canonical service name from the shared services map."
  type        = string
}

variable "port" {
  description = "Container port. Must match the Dockerfile EXPOSE / CMD --port."
  type        = number
}

variable "cpu" {
  description = "Container Apps cpu (float, e.g. 0.5)."
  type        = number
}

variable "memory" {
  description = "Container Apps memory (string, e.g. \"1Gi\")."
  type        = string
}

variable "image_url" {
  description = "Fully qualified ACR image URL (with :latest tag)."
  type        = string
}

variable "azure_name_prefix" {
  description = "Short prefix used for Azure resource names that have tighter length limits than the project-default smarthome-<env>-... prefix."
  type        = string
}

variable "environment" {
  type = string
}

variable "log_level" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "container_app_environment_id" {
  type = string
}

variable "registry_id" {
  type = string
}

variable "registry_login_server" {
  type = string
}

variable "min_instances" {
  type = number
}

variable "max_instances" {
  type = number
}

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------
variable "db_host" {
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
  description = "Database password. Interpolated into DATABASE_URL inside the rendered env list. Terraform marks it sensitive in plan output, but the Container App stores DATABASE_URL in plaintext on the revision (visible via `az containerapp show`). Pre-existing situation — not refactor-introduced. For real deployments, move the credential to Key Vault and reference it via the existing `secret {}` block pattern."
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Key Vault secrets
# ---------------------------------------------------------------------------
variable "key_vault_url" {
  type = string
}

variable "jwt_secret_id" {
  description = "Versionless Key Vault secret URI for JWT_SECRET."
  type        = string
}

variable "jwt_secret_scope" {
  description = "Versionless Azure resource ID for the JWT secret, used as the RBAC scope."
  type        = string
}

variable "internal_token_id" {
  description = "Versionless Key Vault secret URI for INTERNAL_TOKEN."
  type        = string
}

variable "internal_token_scope" {
  description = "Versionless Azure resource ID for the internal token secret."
  type        = string
}

variable "tuya_secret_id" {
  description = "Versionless Key Vault secret URI for Tuya credentials. Only the tuya-bridge instance actually uses this (gated by grant_tuya_secret_access)."
  type        = string
}

variable "tuya_secret_scope" {
  description = "Versionless Azure resource ID for the Tuya secret."
  type        = string
}

variable "tuya_secret_name" {
  description = "Short Key Vault secret name for SECRET_NAME env."
  type        = string
}

variable "grant_tuya_secret_access" {
  description = "When true, create a Key Vault Secrets User role assignment scoped to the Tuya secret. Only tuya-bridge needs this."
  type        = bool
  default     = false
}

variable "tuya_device_ids" {
  description = "Optional comma-separated allowlist of Tuya device IDs."
  type        = string
}

# ---------------------------------------------------------------------------
# Service Bus
# ---------------------------------------------------------------------------
variable "servicebus_namespace_fqdn" {
  type = string
}

variable "servicebus_queue_name" {
  type = string
}

variable "servicebus_queue_id" {
  type = string
}

variable "servicebus_dlq_name" {
  type = string
}

variable "servicebus_role" {
  description = "Service Bus data-plane role to grant this service's identity. One of: \"sender\" (Azure Service Bus Data Sender — device-service), \"receiver\" (Azure Service Bus Data Receiver — analytics-service), or \"none\" (everyone else). Kept inside the module so the Container App can depend_on the role assignment, mirroring the IAM-before-revision-start gotcha from GCP."
  type        = string
  default     = "none"
  validation {
    condition     = contains(["sender", "receiver", "none"], var.servicebus_role)
    error_message = "servicebus_role must be one of: sender, receiver, none."
  }
}

# ---------------------------------------------------------------------------
# Cross-service URLs
# ---------------------------------------------------------------------------
variable "device_service_url" {
  description = "URL of device-service. Set only on the services that call it (analytics, automation, and tuya-bridge via post-create patch)."
  type        = string
  default     = ""
}

variable "tuya_bridge_url" {
  description = "URL of tuya-bridge. Set only on device-service."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Lifecycle / drift handling
# ---------------------------------------------------------------------------
variable "ignore_env_changes" {
  description = "When true, ignore drift on template[0].container[0].env. Used for tuya-bridge whose DEVICE_SERVICE_URL is patched in by a parent-level null_resource after create. Two-resource-blocks-with-count workaround for Terraform's static lifecycle meta-argument — same pattern as the GCP per-service module."
  type        = bool
  default     = false
}
