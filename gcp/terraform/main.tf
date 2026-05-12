# =============================================================================
# Smart Home Hub Platform — GCP Main Terraform Configuration
# =============================================================================
# GCP services used:
# - Cloud Run (Compute, per-service *.run.app URLs)
# - Cloud SQL Postgres (Database, reached via Cloud SQL Auth Proxy)
# - Artifact Registry (Container images)
#
# Out of scope for this PR (still TODO):
# - Pub/Sub to replace SQS for device events
# - Secret Manager to replace plain env vars for JWT_SECRET / INTERNAL_TOKEN
# - Service code abstraction so boto3 isn't called at runtime
# - Cross-service URL plumbing (TUYA_BRIDGE_URL / DEVICE_SERVICE_URL)
#
# Once the SDK abstraction lands, these come back; until then services
# deploy and start but their cross-service / queue / secret calls will
# fail at runtime. See gcp/README.md.
# =============================================================================

terraform {
  required_version = ">= 1.0.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

# =============================================================================
# Local Variables
# =============================================================================
locals {
  name_prefix = "smarthome-${var.environment}"

  # Cloud Run resource limits use string units ("1", "512Mi") rather than
  # ECS's CPU shares / MB. 1 vCPU + 512Mi mirrors db.t3.micro-class sizing
  # and stays within free-tier headroom for short-lived demos.
  services = {
    device-service = {
      port   = 8001
      cpu    = "1"
      memory = "512Mi"
      owner  = "Member1"
    }
    automation-service = {
      port   = 8002
      cpu    = "1"
      memory = "512Mi"
      owner  = "Member2"
    }
    user-service = {
      port   = 8003
      cpu    = "1"
      memory = "512Mi"
      owner  = "Member3"
    }
    analytics-service = {
      port   = 8004
      cpu    = "1"
      memory = "512Mi"
      owner  = "Member4"
    }
    tuya-bridge = {
      port   = 8005
      cpu    = "1"
      memory = "512Mi"
      owner  = "Platform"
    }
  }
}

# =============================================================================
# Shared application secrets (still plain values for now)
# =============================================================================
resource "random_password" "jwt_secret" {
  length  = 48
  special = false
}

resource "random_password" "internal_token" {
  length  = 48
  special = false
}

# =============================================================================
# Artifact Registry — build and push images
# =============================================================================
module "registry" {
  source = "./modules/registry"

  project_id  = var.gcp_project_id
  region      = var.gcp_region
  name_prefix = local.name_prefix
  services    = local.services
}

# =============================================================================
# Cloud SQL Postgres
# =============================================================================
module "database" {
  source = "./modules/database"

  name_prefix = local.name_prefix
  region      = var.gcp_region
  db_username = var.db_username
  db_password = var.db_password
}

# =============================================================================
# Cloud Run services
# =============================================================================
module "cloud_run" {
  source = "./modules/cloud-run"

  project_id  = var.gcp_project_id
  region      = var.gcp_region
  name_prefix = local.name_prefix
  environment = var.environment

  services           = local.services
  image_urls         = module.registry.image_urls
  db_connection_name = module.database.connection_name
  db_name            = module.database.db_name
  db_username        = var.db_username
  db_password        = var.db_password

  jwt_secret      = random_password.jwt_secret.result
  internal_token  = random_password.internal_token.result
  tuya_device_ids = var.tuya_device_ids

  min_instances = var.min_instances
  max_instances = var.max_instances
  log_level     = var.log_level
}

# =============================================================================
# Outputs
# =============================================================================
output "service_urls" {
  description = "Per-service public URLs (*.run.app). There is no shared API Gateway in this deployment — each service is reached directly."
  value       = module.cloud_run.service_urls
}

output "db_connection_name" {
  description = "Cloud SQL connection name for ad-hoc psql via the Auth Proxy."
  value       = module.database.connection_name
}
