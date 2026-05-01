# =============================================================================
# IoT Module - Variables
# =============================================================================

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "tuya_device_ids" {
  description = "Comma-separated list of Tuya device IDs"
  type        = string
  default     = ""
}

variable "tuya_client_id" {
  description = "Tuya Cloud API client ID"
  type        = string
  default     = ""
  sensitive   = true
}

variable "tuya_client_secret" {
  description = "Tuya Cloud API client secret"
  type        = string
  default     = ""
  sensitive   = true
}

variable "tuya_region" {
  description = "Tuya API region"
  type        = string
  default     = "us"
}

variable "common_tags" {
  description = "Common tags for all resources"
  type        = map(string)
}

variable "enable_timestream" {
  description = "Enable Timestream for device metrics (requires existing Timestream access)"
  type        = bool
  default     = false
}
