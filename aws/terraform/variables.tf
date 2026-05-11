# =============================================================================
# Smart Home Hub Platform - Variables
# =============================================================================

variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-east-1"
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

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
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

variable "tuya_device_ids" {
  description = "Comma-separated list of Tuya device IDs to sync (leave blank if not using Tuya)"
  type        = string
}

variable "tuya_client_id" {
  description = "Tuya Cloud API client ID (leave blank if not using Tuya)"
  type        = string
  sensitive   = true
}

variable "tuya_client_secret" {
  description = "Tuya Cloud API client secret (leave blank if not using Tuya)"
  type        = string
  sensitive   = true
}

variable "tuya_region" {
  description = "Tuya API region (us, eu, cn, in)"
  type        = string
  default     = "us"
}

# =============================================================================
# Feature Flags
# =============================================================================

variable "enable_iot_core" {
  description = "Enable AWS IoT Core integration"
  type        = bool
  default     = true
}

variable "enable_timestream" {
  description = "Enable Timestream for metrics (closed to new AWS customers since 2025)"
  type        = bool
  default     = false
}

variable "desired_count" {
  description = "Number of task replicas per microservice (set 2+ to demo the load balancer)"
  type        = number
  default     = 2
}
