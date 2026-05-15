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
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
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

  # GCP-only per-service knobs merged on top of the shared services map
  # (see ../../services.tf). Cloud Run resource limits use string units
  # ("1" vCPU, "512Mi" memory) rather than ECS's CPU shares / MB —
  # different shape per cloud, so these stay per-cloud.
  gcp_overrides = {
    device-service     = { cpu = "1", memory = "512Mi" }
    automation-service = { cpu = "1", memory = "512Mi" }
    user-service       = { cpu = "1", memory = "512Mi" }
    analytics-service  = { cpu = "1", memory = "512Mi" }
    tuya-bridge        = { cpu = "1", memory = "512Mi" }
  }

  services = {
    for k, v in var.services : k => merge(v, local.gcp_overrides[k])
  }
}

# =============================================================================
# Shared application secrets (Secret Manager-backed)
# =============================================================================
# JWT signing secret + service-to-service auth token live in Secret
# Manager. Cloud Run fetches them at container start via the env block's
# `value_source.secret_key_ref` (see modules/cloud-run/main.tf), mirroring
# the AWS task definition's `secrets` block.
#
# Both rotate on `terraform taint random_password.<name>`; services pick
# up the new version on next deploy.
resource "random_password" "jwt_secret" {
  length  = 48
  special = false
}

resource "google_secret_manager_secret" "jwt_secret" {
  secret_id = "${local.name_prefix}-jwt-secret"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "jwt_secret" {
  secret      = google_secret_manager_secret.jwt_secret.id
  secret_data = random_password.jwt_secret.result
}

resource "random_password" "internal_token" {
  length  = 48
  special = false
}

resource "google_secret_manager_secret" "internal_token" {
  secret_id = "${local.name_prefix}-internal-token"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "internal_token" {
  secret      = google_secret_manager_secret.internal_token.id
  secret_data = random_password.internal_token.result
}

# IAM for these two secrets lives inside the cloud-run module (see
# modules/cloud-run/main.tf — google_secret_manager_secret_iam_member.
# app_secrets). The Cloud Run service resources depend_on those grants
# so the first revision can't try to start before the IAM lands.

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
  member = "serviceAccount:${module.device_service.service_account_email}"
}

resource "google_pubsub_subscription_iam_member" "analytics_subscriber" {
  subscription = google_pubsub_subscription.device_events.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${module.service["analytics-service"].service_account_email}"
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
  member    = "serviceAccount:${module.tuya_bridge.service_account_email}"
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

# Small buffer between Cloud Run teardown and the Cloud SQL instance
# restart that the database module triggers next (see
# null_resource.terminate_db_connections in modules/database/main.tf).
# Terraform already waits for Cloud Run delete operations to complete,
# so this is just a margin in case container cleanup lags behind the
# API "deleted" signal. The actual session reaping is done by the
# instance restart, not by waiting. No-op on apply.
resource "time_sleep" "cloud_run_drain" {
  depends_on       = [module.database]
  destroy_duration = "30s"
}

# =============================================================================
# Cloud Run services — three module calls of one shared body
# =============================================================================
# The same `./modules/service` body is used three ways. The split is
# forced by Terraform's self-referential-block check: a for_each can't
# reference a sibling instance, so any service that is both a target of
# a cross-reference (device-service.uri is read by others) and lives
# in the same for_each as its referrers will fail at plan.
#
# Shape:
#   - module.device_service   — singleton anchor. Its uri is fed into
#                                the for_each block as DEVICE_SERVICE_URL.
#                                Itself reads tuya_bridge_url (no cycle:
#                                tuya_bridge has no input from device).
#   - module.service[*]       — for_each over [automation, user, analytics].
#                                Three services that don't sit on either
#                                side of a cross-ref cycle.
#   - module.tuya_bridge      — singleton with ignore_env_changes = true.
#                                DEVICE_SERVICE_URL gets patched in by
#                                null_resource.patch_tuya_bridge_url
#                                below, after device-service exists.
#
# Common inputs are factored into local.service_common to keep the
# three call sites readable.
locals {
  service_common = {
    name_prefix        = local.name_prefix
    environment        = var.environment
    log_level          = var.log_level
    project_id         = var.gcp_project_id
    region             = var.gcp_region
    min_instances      = var.min_instances
    max_instances      = var.max_instances
    db_connection_name = module.database.connection_name
    db_name            = module.database.db_name
    db_username        = var.db_username
    db_password        = var.db_password
    jwt_secret_id      = google_secret_manager_secret.jwt_secret.secret_id
    internal_token_id  = google_secret_manager_secret.internal_token.secret_id
    event_topic        = google_pubsub_topic.device_events.name
    event_subscription = google_pubsub_subscription.device_events.name
    tuya_secret_name   = google_secret_manager_secret.tuya_credentials.secret_id
    tuya_device_ids    = var.tuya_device_ids
  }
}

module "tuya_bridge" {
  source = "./modules/service"

  service_name = "tuya-bridge"
  port         = local.services["tuya-bridge"].port
  cpu          = local.services["tuya-bridge"].cpu
  memory       = local.services["tuya-bridge"].memory
  image_url    = module.registry.image_urls["tuya-bridge"]

  name_prefix        = local.service_common.name_prefix
  environment        = local.service_common.environment
  log_level          = local.service_common.log_level
  project_id         = local.service_common.project_id
  region             = local.service_common.region
  min_instances      = local.service_common.min_instances
  max_instances      = local.service_common.max_instances
  db_connection_name = local.service_common.db_connection_name
  db_name            = local.service_common.db_name
  db_username        = local.service_common.db_username
  db_password        = local.service_common.db_password
  jwt_secret_id      = local.service_common.jwt_secret_id
  internal_token_id  = local.service_common.internal_token_id
  event_topic        = local.service_common.event_topic
  event_subscription = local.service_common.event_subscription
  tuya_secret_name   = local.service_common.tuya_secret_name
  tuya_device_ids    = local.service_common.tuya_device_ids

  # DEVICE_SERVICE_URL is patched in post-create — see
  # null_resource.patch_tuya_bridge_url below.
  ignore_env_changes = true

  depends_on = [time_sleep.cloud_run_drain]
}

module "device_service" {
  source = "./modules/service"

  service_name = "device-service"
  port         = local.services["device-service"].port
  cpu          = local.services["device-service"].cpu
  memory       = local.services["device-service"].memory
  image_url    = module.registry.image_urls["device-service"]

  name_prefix        = local.service_common.name_prefix
  environment        = local.service_common.environment
  log_level          = local.service_common.log_level
  project_id         = local.service_common.project_id
  region             = local.service_common.region
  min_instances      = local.service_common.min_instances
  max_instances      = local.service_common.max_instances
  db_connection_name = local.service_common.db_connection_name
  db_name            = local.service_common.db_name
  db_username        = local.service_common.db_username
  db_password        = local.service_common.db_password
  jwt_secret_id      = local.service_common.jwt_secret_id
  internal_token_id  = local.service_common.internal_token_id
  event_topic        = local.service_common.event_topic
  event_subscription = local.service_common.event_subscription
  tuya_secret_name   = local.service_common.tuya_secret_name
  tuya_device_ids    = local.service_common.tuya_device_ids

  # device-service dispatches commands to tuya-bridge. The reverse
  # direction (DEVICE_SERVICE_URL on tuya-bridge) is patched in by
  # null_resource below — that's how the cycle is broken.
  tuya_bridge_url = module.tuya_bridge.url

  depends_on = [time_sleep.cloud_run_drain]
}

module "service" {
  source = "./modules/service"

  for_each = {
    for k, v in local.services :
    k => v if !contains(["device-service", "tuya-bridge"], k)
  }

  service_name = each.key
  port         = each.value.port
  cpu          = each.value.cpu
  memory       = each.value.memory
  image_url    = module.registry.image_urls[each.key]

  name_prefix        = local.service_common.name_prefix
  environment        = local.service_common.environment
  log_level          = local.service_common.log_level
  project_id         = local.service_common.project_id
  region             = local.service_common.region
  min_instances      = local.service_common.min_instances
  max_instances      = local.service_common.max_instances
  db_connection_name = local.service_common.db_connection_name
  db_name            = local.service_common.db_name
  db_username        = local.service_common.db_username
  db_password        = local.service_common.db_password
  jwt_secret_id      = local.service_common.jwt_secret_id
  internal_token_id  = local.service_common.internal_token_id
  event_topic        = local.service_common.event_topic
  event_subscription = local.service_common.event_subscription
  tuya_secret_name   = local.service_common.tuya_secret_name
  tuya_device_ids    = local.service_common.tuya_device_ids

  # analytics-service queries device-service for live counts;
  # automation-service issues device commands as part of rule execution
  # (e.g., /chase). user-service doesn't call device — the extra env
  # var is harmless. Filtering it out per-service would mean splitting
  # the for_each further; not worth the readability cost.
  device_service_url = module.device_service.url

  depends_on = [time_sleep.cloud_run_drain]
}

# =============================================================================
# Post-create patch: DEVICE_SERVICE_URL on tuya-bridge
# =============================================================================
# tuya-bridge doesn't know device-service's URL at create time (it
# can't — see module header). We create tuya-bridge first (no cross-ref),
# create device-service (which references tuya-bridge.uri), then patch
# tuya-bridge with device-service's URL via gcloud.
#
# replace_triggered_by re-runs the patch whenever tuya-bridge is
# replaced for any reason (image change, resource-limit change, etc.) —
# without it, those updates would create a new revision from the
# declared template (which lacks DEVICE_SERVICE_URL) and silently drop
# the URL until someone noticed.
resource "null_resource" "patch_tuya_bridge_url" {
  # `latest_created_revision` changes on every in-place update of the
  # tuya-bridge Cloud Run service (image change, resource-limit change,
  # etc.), which is what we want to retrigger the patch on. From parent
  # scope we can't use `replace_triggered_by` (it requires literal
  # resource references and can't see across module boundaries), so we
  # surface the revision string as a module output and trigger on it.
  triggers = {
    tuya_bridge_revision = module.tuya_bridge.latest_created_revision
    device_service_url   = module.device_service.url
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      TUYA_NAME="${local.name_prefix}-tuya-bridge"
      echo ">>> Patching DEVICE_SERVICE_URL on $${TUYA_NAME}"
      gcloud run services update "$${TUYA_NAME}" \
        --region="${var.gcp_region}" \
        --project="${var.gcp_project_id}" \
        --update-env-vars="DEVICE_SERVICE_URL=${module.device_service.url}" \
        --quiet >/dev/null
    EOT
  }
}

# =============================================================================
# Outputs
# =============================================================================
output "service_urls" {
  description = "Per-service public URLs (*.run.app). Composed from the three module call sites. There is no shared API Gateway in this deployment — each service is reached directly."
  value = merge(
    { "device-service" = module.device_service.url },
    { "tuya-bridge" = module.tuya_bridge.url },
    { for k, mod in module.service : k => mod.url },
  )
}

output "db_connection_name" {
  description = "Cloud SQL connection name for ad-hoc psql via the Auth Proxy."
  value       = module.database.connection_name
}
