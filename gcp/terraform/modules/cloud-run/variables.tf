# Cloud Run Module Variables

variable "project_id" {
  type = string
}

variable "region" {
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
    cpu    = string
    memory = string
    owner  = string
  }))
}

variable "image_urls" {
  description = "Map of service name -> fully qualified Artifact Registry image URL (with :latest tag). Output of the registry module."
  type        = map(string)
}

variable "db_connection_name" {
  description = "Cloud SQL connection name (project:region:instance). Mounted as /cloudsql/<name>/.s.PGSQL.5432 by the Auth Proxy."
  type        = string
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

variable "jwt_secret" {
  description = "JWT signing secret. Plain env var for now; move to Secret Manager when we tighten IAM."
  type        = string
  sensitive   = true
}

variable "internal_token" {
  description = "Shared service-to-service auth token. Plain env var for now."
  type        = string
  sensitive   = true
}

variable "tuya_device_ids" {
  description = "Optional comma-separated allowlist of Tuya device IDs"
  type        = string
  default     = ""
}

variable "event_topic" {
  description = "Short name of the Pub/Sub topic device-service publishes to."
  type        = string
}

variable "event_subscription" {
  description = "Short name of the Pub/Sub subscription analytics-service pulls from."
  type        = string
}

variable "tuya_secret_name" {
  description = "Short name of the Secret Manager secret holding Tuya creds. Read by tuya-bridge only."
  type        = string
}

variable "min_instances" {
  description = "Minimum number of warm instances per service. 2+ to demo the load balancer."
  type        = number
  default     = 2
}

variable "max_instances" {
  description = "Maximum number of instances per service. Cloud Run scales between min and max."
  type        = number
  default     = 4
}

variable "log_level" {
  type    = string
  default = "INFO"
}
