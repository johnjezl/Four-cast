# =============================================================================
# Smart Home Hub Platform — GCP Variables
# =============================================================================

variable "gcp_project_id" {
  description = "GCP project ID to deploy into."
  type        = string
}

variable "gcp_region" {
  description = "GCP region for Cloud Run, Cloud SQL, and Artifact Registry."
  type        = string
  default     = "us-central1"
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
  description = "Database master username"
  type        = string
  default     = "smarthome_admin"
  sensitive   = true
}

variable "db_password" {
  description = "Database master password"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.db_password) >= 8
    error_message = "Database password must be at least 8 characters."
  }
}

# =============================================================================
# Tuya Integration
# =============================================================================
# Tuya credentials live in Secret Manager and are read by tuya-bridge at
# startup. Granting access is scoped to that one service via the cloud-
# run module's per-service runtime SA.

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
  description = "Cloud Run min instance count per service (2+ to demo the load balancer)."
  type        = number
  default     = 2
}

variable "max_instances" {
  description = "Cloud Run max instance count per service."
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
