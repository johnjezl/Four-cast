# =============================================================================
# Cloud Run Module
# =============================================================================
# One google_cloud_run_v2_service per microservice. Cloud Run handles
# request-level load balancing internally; min_instance_count >= 2 keeps
# two warm containers per service for the LB demo.
#
# Cross-service URLs (TUYA_BRIDGE_URL, DEVICE_SERVICE_URL) are NOT set
# here — they're cyclic between device-service and tuya-bridge, and the
# AWS-shaped service code in this folder uses boto3 anyway. Both gaps are
# addressed in the follow-up that abstracts the SDK layer.
#
# Each service gets a dedicated service account so IAM can be tightened
# per service later (e.g., only tuya-bridge reads the Tuya secret).
# =============================================================================

# -----------------------------------------------------------------------------
# Per-service service accounts
# -----------------------------------------------------------------------------
resource "google_service_account" "services" {
  for_each = var.services

  # GCP caps account_id at 30 chars. "smarthome-${env}-${service}" blows
  # past that for "-service"-suffixed keys (e.g.
  # "smarthome-dev-automation-service" = 32). Strip the redundant suffix
  # so all five service keys fit at every env value.
  account_id   = replace("${var.name_prefix}-${each.key}", "-service", "")
  display_name = "Cloud Run runtime SA for ${each.key}"
}

# Cloud SQL Auth Proxy access. Cloud Run mounts the proxy via the
# cloud_sql_instance volume; the runtime SA needs the client role to use it.
resource "google_project_iam_member" "cloud_sql_client" {
  for_each = var.services

  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.services[each.key].email}"
}

# -----------------------------------------------------------------------------
# Cloud Run services
# -----------------------------------------------------------------------------
resource "google_cloud_run_v2_service" "main" {
  for_each = var.services

  name     = "${var.name_prefix}-${each.key}"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.services[each.key].email

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    # Cloud SQL Auth Proxy: makes the instance reachable at the
    # /cloudsql/<connection-name> unix socket inside the container.
    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [var.db_connection_name]
      }
    }

    containers {
      image = var.image_urls[each.key]

      ports {
        container_port = each.value.port
      }

      resources {
        limits = {
          cpu    = each.value.cpu
          memory = each.value.memory
        }
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }

      # Match the ALB health check on the AWS side: probe /health and
      # let Cloud Run recycle the instance if FastAPI ever wedges with
      # the port open. Default startup probe is a TCP open on the port,
      # which wouldn't catch that case.
      #
      # Budget: 10s delay + 6 × 10s = 70s to come up. FastAPI cold start
      # + Cloud SQL Auth Proxy handshake is comfortably inside that.
      startup_probe {
        http_get {
          path = "/health"
          port = each.value.port
        }
        initial_delay_seconds = 10
        period_seconds        = 10
        timeout_seconds       = 5
        failure_threshold     = 6
      }

      # Runtime hang detection. Startup_probe only fires once; without
      # liveness_probe a wedged FastAPI process keeps serving the port
      # forever. 30s period mirrors the AWS ALB health check interval.
      liveness_probe {
        http_get {
          path = "/health"
          port = each.value.port
        }
        period_seconds    = 30
        timeout_seconds   = 5
        failure_threshold = 3
      }

      # shared.cloud picks the GCP adapter (Pub/Sub + Secret Manager)
      # based on CLOUD_PROVIDER. The adapter reads EVENT_TOPIC /
      # EVENT_SUBSCRIPTION / GCP_PROJECT from the env.
      env {
        name  = "CLOUD_PROVIDER"
        value = "gcp"
      }
      env {
        name  = "GCP_PROJECT"
        value = var.project_id
      }
      env {
        name  = "EVENT_TOPIC"
        value = var.event_topic
      }
      env {
        name  = "EVENT_SUBSCRIPTION"
        value = var.event_subscription
      }
      env {
        name  = "SECRET_NAME"
        value = var.tuya_secret_name
      }
      env {
        name  = "SERVICE_NAME"
        value = each.key
      }
      env {
        name  = "PORT"
        value = tostring(each.value.port)
      }
      env {
        name  = "ENVIRONMENT"
        value = var.environment
      }
      env {
        name  = "LOG_LEVEL"
        value = var.log_level
      }
      # asyncpg uses ?host=<path> to talk over a unix socket. The Cloud
      # SQL Auth Proxy creates /cloudsql/<connection-name>/.s.PGSQL.5432
      # automatically.
      env {
        name  = "DATABASE_URL"
        value = "postgresql+asyncpg://${var.db_username}:${var.db_password}@/${var.db_name}?host=/cloudsql/${var.db_connection_name}"
      }
      # Plain env vars for now. Promote to Secret Manager when we tighten
      # IAM in a follow-up — same pattern as the AWS task definition's
      # `secrets` block.
      env {
        name  = "JWT_SECRET"
        value = var.jwt_secret
      }
      env {
        name  = "INTERNAL_TOKEN"
        value = var.internal_token
      }
      env {
        name  = "TUYA_DEVICE_IDS"
        value = var.tuya_device_ids
      }
    }
  }

  # Suppress drift on metadata Cloud Run auto-populates each apply.
  lifecycle {
    ignore_changes = [
      client,
      client_version,
    ]
  }
}

# -----------------------------------------------------------------------------
# Invoker IAM
# -----------------------------------------------------------------------------
# Every service except tuya-bridge gets allUsers as run.invoker. AWS had
# to hide tuya-bridge behind an INTERNAL_TOKEN check at the app layer
# because the ALB was public; GCP lets us enforce it at the IAM edge so
# random internet traffic never reaches the container at all.
#
# Coupling: the literal "tuya-bridge" must match the key used by callers
# in main.tf. Symmetric to the AWS module's tuya-bridge IAM coupling
# (aws/terraform/modules/ecs/main.tf) — rename either side and the
# bridge silently loses callers.
resource "google_cloud_run_v2_service_iam_member" "public" {
  for_each = { for k, v in var.services : k => v if k != "tuya-bridge" }

  project  = google_cloud_run_v2_service.main[each.key].project
  location = google_cloud_run_v2_service.main[each.key].location
  name     = google_cloud_run_v2_service.main[each.key].name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# tuya-bridge is only reachable by device-service's runtime SA. When the
# SDK abstraction lands, device-service will need to mint a Google ID
# token signed by its own SA to call the bridge; until then this is
# defense in depth (the bridge is broken-but-unreachable rather than
# broken-and-exposed).
resource "google_cloud_run_v2_service_iam_member" "tuya_bridge_internal" {
  project  = google_cloud_run_v2_service.main["tuya-bridge"].project
  location = google_cloud_run_v2_service.main["tuya-bridge"].location
  name     = google_cloud_run_v2_service.main["tuya-bridge"].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.services["device-service"].email}"
}
