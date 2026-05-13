# =============================================================================
# Smart Home Hub Platform - Azure Variables
# =============================================================================

variable "azure_subscription_id" {
  description = "Azure subscription ID to deploy into. Required by the AzureRM provider for plan/apply."
  type        = string
}

variable "azure_location" {
  description = "Azure region for Container Apps, PostgreSQL, ACR, Service Bus, and Key Vault."
  type        = string
  default     = "eastus"
}

# Some subscriptions (student / sponsorship / free tier) refuse Postgres
# Flexible Server provisioning in certain regions with `LocationIsOfferRestricted`.
# When that happens, set db_location to a region where the subscription has
# Postgres quota (commonly eastus2 or centralus). Container Apps in the
# primary region then make cross-region calls to Postgres — adds a few ms
# of latency and a small egress charge, but keeps the rest of the topology
# in one place. Leave blank to use azure_location.
variable "db_location" {
  description = "Override region for the Postgres Flexible Server. Blank means use azure_location."
  type        = string
  default     = ""
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be dev, staging, or prod."
  }
}

variable "db_username" {
  description = "Database administrator username"
  type        = string
  default     = "smarthome_admin"
  sensitive   = true
}

variable "db_password" {
  description = "Database administrator password"
  type        = string
  sensitive   = true

  # Azure Postgres Flexible Server requires 8-128 chars and 3 of 4 character
  # classes (upper, lower, digit, special). Catching this client-side avoids
  # a ~5 min mid-apply failure at server-create time. The password is also
  # interpolated raw into DATABASE_URL, so reject URL-reserved characters
  # (@ : / ? # %) that would break the DSN parser on the service side.
  validation {
    condition = (
      length(var.db_password) >= 8 &&
      length(var.db_password) <= 128 &&
      (
        (can(regex("[A-Z]", var.db_password)) ? 1 : 0) +
        (can(regex("[a-z]", var.db_password)) ? 1 : 0) +
        (can(regex("[0-9]", var.db_password)) ? 1 : 0) +
        (can(regex("[^A-Za-z0-9]", var.db_password)) ? 1 : 0)
      ) >= 3 &&
      !can(regex("[@:/?#%]", var.db_password))
    )
    error_message = "db_password must be 8-128 chars, contain at least 3 of {upper, lower, digit, special}, and must not contain @ : / ? # % (breaks DATABASE_URL parsing)."
  }
}

# =============================================================================
# Tuya Integration
# =============================================================================
# Tuya credentials live in Key Vault and are read by tuya-bridge at
# startup. Access is scoped to the tuya-bridge managed identity.

variable "tuya_device_ids" {
  description = "Optional comma-separated allowlist of Tuya device IDs to sync."
  type        = string
  default     = ""
}

variable "tuya_client_id" {
  description = "Tuya Cloud API client ID (leave blank if not using Tuya)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "tuya_client_secret" {
  description = "Tuya Cloud API client secret (leave blank if not using Tuya)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "tuya_region" {
  description = "Tuya API region (us, eu, cn, in)."
  type        = string
  default     = "us"
}

variable "min_instances" {
  description = "Container Apps min replica count per service. Keep at 0 for demos unless actively load-testing."
  type        = number
  default     = 0
}

variable "max_instances" {
  description = "Container Apps max replica count per service."
  type        = number
  default     = 4
}

variable "log_level" {
  description = "Python logging level for the microservices (DEBUG, INFO, WARNING, ERROR). DEBUG also enables SQLAlchemy query echo."
  type        = string
  default     = "INFO"

  validation {
    condition     = contains(["DEBUG", "INFO", "WARNING", "ERROR"], upper(var.log_level))
    error_message = "log_level must be one of DEBUG, INFO, WARNING, ERROR."
  }
}
