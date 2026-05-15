# Cluster module variables. Per-service config has moved to
# aws/terraform/modules/service/ — this module owns only the shared
# cluster, ALB, IAM, and security groups.

variable "name_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "jwt_secret_arn" {
  description = "Secrets Manager ARN for the JWT signing secret. Granted to the execution role so the ECS agent can fetch it at container start."
  type        = string
}

variable "internal_token_arn" {
  description = "Secrets Manager ARN for the service-to-service auth token."
  type        = string
}

variable "tuya_secret_arn" {
  description = "ARN of the Tuya Secrets Manager secret. Granted only to the tuya-bridge task role."
  type        = string
}

variable "common_tags" {
  type = map(string)
}
