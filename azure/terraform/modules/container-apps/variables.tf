# Container Apps Module Variables

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "name_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "services" {
  type = map(object({
    port   = number
    cpu    = number
    memory = string
    owner  = string
  }))
}

variable "image_urls" {
  description = "Map of service name -> fully qualified ACR image URL (with :latest tag). Output of the registry module."
  type        = map(string)
}

variable "registry_id" {
  type = string
}

variable "registry_login_server" {
  type = string
}

variable "db_host" {
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
  description = "Versionless Azure resource ID for the internal token secret, used as the RBAC scope."
  type        = string
}

variable "tuya_secret_id" {
  description = "Versionless Key Vault secret URI for Tuya credentials."
  type        = string
}

variable "tuya_secret_scope" {
  description = "Versionless Azure resource ID for the Tuya secret, used as the RBAC scope."
  type        = string
}

variable "tuya_secret_name" {
  description = "Short Key Vault secret name holding Tuya creds. Read by tuya-bridge only."
  type        = string
}

variable "tuya_device_ids" {
  description = "Optional comma-separated allowlist of Tuya device IDs."
  type        = string
  default     = ""
}

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

variable "min_instances" {
  description = "Minimum number of replicas per service."
  type        = number
  default     = 0
}

variable "max_instances" {
  description = "Maximum number of replicas per service."
  type        = number
  default     = 4
}

variable "log_level" {
  type    = string
  default = "INFO"
}

variable "tags" {
  type    = map(string)
  default = {}
}
