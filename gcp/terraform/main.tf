# =============================================================================
# Smart Home Hub Platform — GCP Main Terraform Configuration
# =============================================================================
# GCP services used:
# - Cloud Run (Compute, per-service *.run.app URLs)
# - Cloud SQL Postgres (Database, reached via Cloud SQL Auth Proxy)
# - Artifact Registry (Container images)
# - Pub/Sub (Device-events bus; consumed by analytics-service)
# - Secret Manager (Tuya Cloud credentials)
#
# Service containers run identical code on AWS and GCP — the shared/
# cloud-abstraction layer (SqsEventBus / PubSubEventBus, SecretsManager-
# Store / SecretManagerStore) is picked at runtime via CLOUD_PROVIDER.
# =============================================================================

terraform {
  required_version = ">= 1.0.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    # google-beta is only used for google_project_service_identity below
    # (forces creation of the Pub/Sub service agent). Everything else
    # uses the stable google provider.
    google-beta = {
      source  = "hashicorp/google-beta"
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

provider "google-beta" {
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
# Pub/Sub: device-events bus
# =============================================================================
# Topic + subscription + dead-letter topic. device-service publishes to
# the topic; analytics-service pulls from the subscription. The DLQ
# mirrors the AWS redrive policy — after 5 redeliveries, Pub/Sub routes
# the message to the dead-letter topic.

data "google_project" "current" {}

# Force creation of the Pub/Sub service agent (the
# service-<project-number>@gcp-sa-pubsub.iam.gserviceaccount.com
# principal) so the DLQ IAM bindings below have a real member to grant
# to. Without this, a first apply on a fresh project can fail with
# "member does not exist" while GCP lazily materializes the agent.
resource "google_project_service_identity" "pubsub" {
  provider = google-beta
  project  = data.google_project.current.project_id
  service  = "pubsub.googleapis.com"
}

resource "google_pubsub_topic" "device_events" {
  name = "${local.name_prefix}-device-events"
}

resource "google_pubsub_topic" "device_events_dlq" {
  name = "${local.name_prefix}-device-events-dlq"
}

resource "google_pubsub_subscription" "device_events" {
  name  = "${local.name_prefix}-device-events-sub"
  topic = google_pubsub_topic.device_events.name

  ack_deadline_seconds = 30

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.device_events_dlq.id
    max_delivery_attempts = 5
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "300s"
  }
}

# Pub/Sub uses a per-project service agent to forward dead-lettered
# messages and to read from subscriptions when DLQ-routing. The agent
# needs publisher rights on the DLQ topic and subscriber rights on the
# source subscription — Google docs call this "configure forwarding".
# The depends_on serializes after google_project_service_identity so
# the agent principal is guaranteed to exist before we IAM-grant to it.
resource "google_pubsub_topic_iam_member" "dlq_publisher" {
  topic      = google_pubsub_topic.device_events_dlq.name
  role       = "roles/pubsub.publisher"
  member     = "serviceAccount:${google_project_service_identity.pubsub.email}"
  depends_on = [google_project_service_identity.pubsub]
}

resource "google_pubsub_subscription_iam_member" "dlq_subscriber" {
  subscription = google_pubsub_subscription.device_events.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${google_project_service_identity.pubsub.email}"
  depends_on   = [google_project_service_identity.pubsub]
}

# Per-service runtime IAM. device-service publishes; analytics-service
# subscribes. Each gets only the role it needs.
resource "google_pubsub_topic_iam_member" "device_service_publisher" {
  topic  = google_pubsub_topic.device_events.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${module.cloud_run.service_account_emails["device-service"]}"
}

resource "google_pubsub_subscription_iam_member" "analytics_subscriber" {
  subscription = google_pubsub_subscription.device_events.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${module.cloud_run.service_account_emails["analytics-service"]}"
}

# =============================================================================
# Secret Manager: Tuya Cloud credentials
# =============================================================================
resource "google_secret_manager_secret" "tuya_credentials" {
  secret_id = "${local.name_prefix}-tuya-credentials"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "tuya_credentials" {
  secret = google_secret_manager_secret.tuya_credentials.id
  secret_data = jsonencode({
    client_id     = var.tuya_client_id
    client_secret = var.tuya_client_secret
    region        = var.tuya_region
  })
}

# Only tuya-bridge can read this secret. Same scoping pattern as the AWS
# tuya-bridge task role.
resource "google_secret_manager_secret_iam_member" "tuya_bridge_accessor" {
  secret_id = google_secret_manager_secret.tuya_credentials.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${module.cloud_run.service_account_emails["tuya-bridge"]}"
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

  event_topic        = google_pubsub_topic.device_events.name
  event_subscription = google_pubsub_subscription.device_events.name
  tuya_secret_name   = google_secret_manager_secret.tuya_credentials.secret_id

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
