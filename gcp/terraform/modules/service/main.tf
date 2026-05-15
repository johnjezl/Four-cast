# =============================================================================
# GCP per-service module
# =============================================================================
# One module *body* instantiated three ways from the parent:
#
#   1. module "device_service" — singleton. Cross-referenced by other
#      services, so it can't sit inside a for_each that also contains
#      its referrers.
#   2. module "service" with for_each — the three "middle" services
#      (automation, user, analytics) that don't sit on either side of
#      a cross-reference cycle.
#   3. module "tuya_bridge" — singleton with ignore_env_changes = true.
#      device-service references tuya-bridge.uri (creates tuya first),
#      then a parent-level null_resource patches DEVICE_SERVICE_URL
#      onto tuya-bridge after both exist. ignore_env_changes keeps
#      Terraform from fighting that patch on subsequent applies.
#
# Templating: the env-var list is rendered via templatefile() from
# templates/env.json.tftpl. Less visually striking than the AWS ECS
# container-def JSON because Cloud Run takes env as native HCL blocks
# (no big JSON blob to template), but the pattern is the same: one
# template, substituted values, visible diff in `terraform plan`.
# Secrets stay as native value_source.secret_key_ref blocks since
# templatefile can't render those.
#
# Why two resource blocks (`default` + `env_ignored`):
# Terraform's lifecycle meta-argument is static — `ignore_changes`
# can't be a conditional expression. The standard workaround is to
# gate two near-identical resources by `count` based on a boolean
# variable, and union their outputs.
# =============================================================================

# -----------------------------------------------------------------------------
# Runtime service account
# -----------------------------------------------------------------------------
resource "google_service_account" "this" {
  # GCP caps account_id at 30 chars. "smarthome-${env}-${service}" blows
  # past that for "-service"-suffixed keys (e.g.
  # "smarthome-dev-automation-service" = 32). Strip the redundant suffix
  # so all five service names fit at every env value.
  account_id   = replace("${var.name_prefix}-${var.service_name}", "-service", "")
  display_name = "Cloud Run runtime SA for ${var.service_name}"
}

# Cloud SQL Auth Proxy access. Cloud Run mounts the proxy via the
# cloud_sql_instance volume; the runtime SA needs the client role.
resource "google_project_iam_member" "cloud_sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.this.email}"
}

# Every service reads JWT_SECRET (JWT validation) and INTERNAL_TOKEN
# (service-to-service auth). Bindings live in the module so the Cloud
# Run resources below can depend_on them — Cloud Run waits for the
# first revision to be READY, and the container can't become READY
# without secret access, so IAM must land first.
resource "google_secret_manager_secret_iam_member" "jwt_secret" {
  project   = var.project_id
  secret_id = var.jwt_secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.this.email}"
}

resource "google_secret_manager_secret_iam_member" "internal_token" {
  project   = var.project_id
  secret_id = var.internal_token_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.this.email}"
}

# -----------------------------------------------------------------------------
# Templated env-var list
# -----------------------------------------------------------------------------
locals {
  database_url = "postgresql+asyncpg://${var.db_username}:${var.db_password}@/${var.db_name}?host=/cloudsql/${var.db_connection_name}"

  # Templated render → JSON string → decoded list. The decoded list is
  # consumed by the `dynamic "env"` block inside the container template.
  env_vars = jsondecode(templatefile("${path.module}/templates/env.json.tftpl", {
    project_id         = var.project_id
    service_name       = var.service_name
    event_topic        = var.event_topic
    event_subscription = var.event_subscription
    tuya_secret_name   = var.tuya_secret_name
    environment        = var.environment
    log_level          = var.log_level
    database_url       = local.database_url
    tuya_device_ids    = var.tuya_device_ids
    device_service_url = var.device_service_url
    tuya_bridge_url    = var.tuya_bridge_url
  }))
}

# -----------------------------------------------------------------------------
# Cloud Run v2 service (default lifecycle)
# -----------------------------------------------------------------------------
resource "google_cloud_run_v2_service" "default" {
  count = var.ignore_env_changes ? 0 : 1

  name     = "${var.name_prefix}-${var.service_name}"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  depends_on = [
    google_secret_manager_secret_iam_member.jwt_secret,
    google_secret_manager_secret_iam_member.internal_token,
    google_project_iam_member.cloud_sql_client,
  ]

  template {
    service_account = google_service_account.this.email

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [var.db_connection_name]
      }
    }

    containers {
      image = var.image_url

      ports {
        container_port = var.port
      }

      resources {
        limits = {
          cpu    = var.cpu
          memory = var.memory
        }
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }

      # 10s delay + 10 × 10s = 110s total budget to come up. FastAPI
      # cold start + Cloud SQL Auth Proxy handshake + first-time DB
      # `metadata.create_all()` is normally well under this, but on
      # fresh applies (cold registry pull, IAM bindings just-propagated,
      # Cloud SQL Auth Proxy first handshake) the tail latency lands
      # right at the previous 70s ceiling — verified in the field with
      # the device-service first-apply race. failure_threshold = 10
      # only widens the budget on *failed* probes; healthy starts still
      # mark Ready as soon as the first 200 OK lands.
      startup_probe {
        http_get {
          path = "/health"
          port = var.port
        }
        initial_delay_seconds = 10
        period_seconds        = 10
        timeout_seconds       = 5
        failure_threshold     = 10
      }

      # Runtime hang detection. 30s mirrors the AWS ALB health-check interval.
      liveness_probe {
        http_get {
          path = "/health"
          port = var.port
        }
        period_seconds    = 30
        timeout_seconds   = 5
        failure_threshold = 3
      }

      dynamic "env" {
        for_each = local.env_vars
        content {
          name  = env.value.name
          value = env.value.value
        }
      }

      # PORT is reserved by Cloud Run (it injects its own from
      # ports.container_port); setting it explicitly is rejected.

      # JWT_SECRET / INTERNAL_TOKEN come from Secret Manager. Cloud
      # Run env blocks can carry either `value` or `value_source`,
      # never both, so the secret-backed entries can't ride in the
      # templated list above.
      env {
        name = "JWT_SECRET"
        value_source {
          secret_key_ref {
            secret  = var.jwt_secret_id
            version = "latest"
          }
        }
      }

      env {
        name = "INTERNAL_TOKEN"
        value_source {
          secret_key_ref {
            secret  = var.internal_token_id
            version = "latest"
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      client,
      client_version,
    ]
  }
}

# -----------------------------------------------------------------------------
# Cloud Run v2 service (env drift ignored — tuya-bridge flavor)
# -----------------------------------------------------------------------------
# Same body, different lifecycle. The null_resource that patches
# DEVICE_SERVICE_URL onto tuya-bridge post-create would otherwise show
# up as drift on subsequent plans; ignore_changes on env silences that.
#
# Trade-off: env declared in this module is "managed by null_resource"
# going forward when ignore_env_changes is true. Terraform-declared env
# changes (e.g., rotating JWT_SECRET via taint) won't auto-apply on
# tuya-bridge — they need a `terraform taint` on the null_resource or
# a manual `gcloud run services update`.
resource "google_cloud_run_v2_service" "env_ignored" {
  count = var.ignore_env_changes ? 1 : 0

  name     = "${var.name_prefix}-${var.service_name}"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  depends_on = [
    google_secret_manager_secret_iam_member.jwt_secret,
    google_secret_manager_secret_iam_member.internal_token,
    google_project_iam_member.cloud_sql_client,
  ]

  template {
    service_account = google_service_account.this.email

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [var.db_connection_name]
      }
    }

    containers {
      image = var.image_url

      ports {
        container_port = var.port
      }

      resources {
        limits = {
          cpu    = var.cpu
          memory = var.memory
        }
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }

      # See startup_probe comment in the `default` block above for the
      # 110s budget rationale. Same body, kept in sync.
      startup_probe {
        http_get {
          path = "/health"
          port = var.port
        }
        initial_delay_seconds = 10
        period_seconds        = 10
        timeout_seconds       = 5
        failure_threshold     = 10
      }

      liveness_probe {
        http_get {
          path = "/health"
          port = var.port
        }
        period_seconds    = 30
        timeout_seconds   = 5
        failure_threshold = 3
      }

      dynamic "env" {
        for_each = local.env_vars
        content {
          name  = env.value.name
          value = env.value.value
        }
      }

      env {
        name = "JWT_SECRET"
        value_source {
          secret_key_ref {
            secret  = var.jwt_secret_id
            version = "latest"
          }
        }
      }

      env {
        name = "INTERNAL_TOKEN"
        value_source {
          secret_key_ref {
            secret  = var.internal_token_id
            version = "latest"
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      client,
      client_version,
      template[0].containers[0].env,
    ]
  }
}

# -----------------------------------------------------------------------------
# Public invoker
# -----------------------------------------------------------------------------
# allUsers as run.invoker mirrors the AWS deployment where the ALB is
# public. App-level auth (JWT + INTERNAL_TOKEN) still gates everything.
locals {
  service = var.ignore_env_changes ? google_cloud_run_v2_service.env_ignored[0] : google_cloud_run_v2_service.default[0]
}

resource "google_cloud_run_v2_service_iam_member" "public" {
  project  = local.service.project
  location = local.service.location
  name     = local.service.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
