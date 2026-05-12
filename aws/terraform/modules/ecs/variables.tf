# ECS Module Variables

variable "name_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "services" {
  type = map(object({
    port        = number
    cpu         = number
    memory      = number
    health_path = string
    owner       = string
    # ALB listener-rule priority. Explicit so adding a new service can't
    # silently renumber existing rules.
    priority = number
  }))
}

variable "db_endpoint" {
  type = string
}

variable "db_name" {
  type    = string
  default = "smarthome"
}

variable "db_username" {
  type      = string
  sensitive = true
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "jwt_secret_arn" {
  description = "Secrets Manager ARN for the JWT signing secret. Injected into containers via the task definition's `secrets` block."
  type        = string
}

variable "internal_token_arn" {
  description = "Secrets Manager ARN for the service-to-service auth token. Injected via `secrets` block."
  type        = string
}

variable "device_events_queue" {
  description = "SQS queue URL for device events; consumed by analytics-service"
  type        = string
}

variable "tuya_secret_name" {
  description = "Name of the Secrets Manager secret holding Tuya credentials"
  type        = string
}

variable "tuya_secret_arn" {
  description = "ARN of the Tuya Secrets Manager secret (for IAM scoping)"
  type        = string
}

variable "tuya_device_ids" {
  description = "Optional comma-separated allowlist of Tuya device IDs"
  type        = string
  default     = ""
}

variable "common_tags" {
  type = map(string)
}

variable "desired_count" {
  description = "Number of task replicas per service (for load-balancer demo)"
  type        = number
  default     = 2
}

variable "log_level" {
  description = "Python logging level for service containers"
  type        = string
  default     = "INFO"
}
