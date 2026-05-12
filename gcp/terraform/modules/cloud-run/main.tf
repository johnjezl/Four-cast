# =============================================================================
# Cloud Run Module
# =============================================================================
# One google_cloud_run_v2_service per microservice. tuya-bridge is split
# into its own resource because device-service and tuya-bridge need to
# know each other's URIs and Cloud Run's for_each instance graph can't
# express that cycle directly — device-service gets TUYA_BRIDGE_URL via
# a Terraform reference at create time, tuya-bridge gets
# DEVICE_SERVICE_URL via a null_resource patch after both exist. The
# split lets us put lifecycle.ignore_changes on the tuya-bridge env
# list so the post-create patch doesn't show as drift.
#
# Trade-off: tuya-bridge env is effectively "managed by null_resource"
# going forward. Terraform-declared changes to its env (e.g. rotating
# JWT_SECRET) won't auto-apply — they need `terraform taint` on the
# null_resource or a manual `gcloud run services update`. The
# documented limitation buys us a working actuator loop without
# building a full service-discovery layer.
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

# App-secret access. Every runtime SA needs to read JWT_SECRET (each
# service validates JWTs) and INTERNAL_TOKEN (every service-to-service
# call is gated by it). Bindings live inside the module so the Cloud
# Run resources below can depend_on them — Cloud Run waits for the
# first revision to be READY at create time, and the container can't
# become READY without secret access, so the IAM has to land first.
locals {
  app_secret_grants = flatten([
    for sa_key, sa in google_service_account.services : [
      {
        key       = "${sa_key}-jwt"
        sa_email  = sa.email
        secret_id = var.jwt_secret_id
      },
      {
        key       = "${sa_key}-internal"
        sa_email  = sa.email
        secret_id = var.internal_token_id
      },
    ]
  ])
}

resource "google_secret_manager_secret_iam_member" "app_secrets" {
  for_each = { for g in local.app_secret_grants : g.key => g }

  project   = var.project_id
  secret_id = each.value.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${each.value.sa_email}"
}

# -----------------------------------------------------------------------------
# Shared template config
# -----------------------------------------------------------------------------
# Both the main for_each and the tuya-bridge singleton drop the same
# base env vars onto every container. Cross-service URL overrides
# (TUYA_BRIDGE_URL, DEVICE_SERVICE_URL) layer on top via dynamic blocks
# in each resource — kept out of locals to avoid forward-reference
# cycles.
locals {
  # Plain env vars shared by every container. Secrets (JWT_SECRET,
  # INTERNAL_TOKEN) are NOT here — they're added separately as static
  # env blocks below with value_source.secret_key_ref. Cloud Run's env
  # block can carry either `value` or `value_source`, never both, so we
  # have to keep the two flavors in separate blocks.
  base_env = [
    { name = "CLOUD_PROVIDER", value = "gcp" },
    { name = "GCP_PROJECT", value = var.project_id },
    { name = "EVENT_TOPIC", value = var.event_topic },
    { name = "EVENT_SUBSCRIPTION", value = var.event_subscription },
    { name = "SECRET_NAME", value = var.tuya_secret_name },
    { name = "ENVIRONMENT", value = var.environment },
    { name = "LOG_LEVEL", value = var.log_level },
    { name = "DATABASE_URL", value = "postgresql+asyncpg://${var.db_username}:${var.db_password}@/${var.db_name}?host=/cloudsql/${var.db_connection_name}" },
    { name = "TUYA_DEVICE_IDS", value = var.tuya_device_ids },
  ]
}

# -----------------------------------------------------------------------------
# Cloud Run services (everything except tuya-bridge)
# -----------------------------------------------------------------------------
resource "google_cloud_run_v2_service" "main" {
  for_each = { for k, v in var.services : k => v if k != "tuya-bridge" }

  name     = "${var.name_prefix}-${each.key}"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  # IAM must exist before the first revision tries to start, otherwise
  # the container fails to fetch its secret and Cloud Run times out
  # marking the revision READY.
  depends_on = [
    google_secret_manager_secret_iam_member.app_secrets,
    google_project_iam_member.cloud_sql_client,
  ]

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
      # the port open.
      #
      # Budget: 10s delay + 6 × 10s = 70s to come up. FastAPI cold
      # start + Cloud SQL Auth Proxy handshake is comfortably inside
      # that.
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

      # Runtime hang detection. 30s period mirrors the AWS ALB health
      # check interval.
      liveness_probe {
        http_get {
          path = "/health"
          port = each.value.port
        }
        period_seconds    = 30
        timeout_seconds   = 5
        failure_threshold = 3
      }

      dynamic "env" {
        for_each = local.base_env
        content {
          name  = env.value.name
          value = env.value.value
        }
      }

      # JWT_SECRET and INTERNAL_TOKEN are pulled from Secret Manager at
      # container start. The runtime SA needs roles/secretmanager.
      # secretAccessor on both secrets (granted in gcp/terraform/main.tf).
      # Mirrors the AWS task definition's `secrets` block.
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

      env {
        name  = "SERVICE_NAME"
        value = each.key
      }
      env {
        name  = "PORT"
        value = tostring(each.value.port)
      }

      # device-service publishes commands to tuya-bridge. Cross-service
      # ref to the split tuya-bridge resource is acyclic because
      # tuya-bridge env doesn't reference back.
      dynamic "env" {
        for_each = each.key == "device-service" ? [google_cloud_run_v2_service.tuya_bridge.uri] : []
        content {
          name  = "TUYA_BRIDGE_URL"
          value = env.value
        }
      }

      # analytics-service queries device-service for live counts.
      # Intra-for_each reference (analytics depends on device-service)
      # is acyclic — device-service doesn't reference analytics back.
      dynamic "env" {
        for_each = each.key == "analytics-service" ? [google_cloud_run_v2_service.main["device-service"].uri] : []
        content {
          name  = "DEVICE_SERVICE_URL"
          value = env.value
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
# Cloud Run: tuya-bridge (split out for the env cycle break)
# -----------------------------------------------------------------------------
# Same template as main[*], minus the cross-service DEVICE_SERVICE_URL,
# which is patched in by null_resource.patch_tuya_bridge_url below
# after device-service exists. lifecycle.ignore_changes on env keeps
# the patch from showing as drift.
resource "google_cloud_run_v2_service" "tuya_bridge" {
  name     = "${var.name_prefix}-tuya-bridge"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  # Same IAM-before-revision-start ordering as main[*].
  depends_on = [
    google_secret_manager_secret_iam_member.app_secrets,
    google_project_iam_member.cloud_sql_client,
  ]

  template {
    service_account = google_service_account.services["tuya-bridge"].email

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
      image = var.image_urls["tuya-bridge"]

      ports {
        container_port = var.services["tuya-bridge"].port
      }

      resources {
        limits = {
          cpu    = var.services["tuya-bridge"].cpu
          memory = var.services["tuya-bridge"].memory
        }
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }

      startup_probe {
        http_get {
          path = "/health"
          port = var.services["tuya-bridge"].port
        }
        initial_delay_seconds = 10
        period_seconds        = 10
        timeout_seconds       = 5
        failure_threshold     = 6
      }

      liveness_probe {
        http_get {
          path = "/health"
          port = var.services["tuya-bridge"].port
        }
        period_seconds    = 30
        timeout_seconds   = 5
        failure_threshold = 3
      }

      dynamic "env" {
        for_each = local.base_env
        content {
          name  = env.value.name
          value = env.value.value
        }
      }

      # Same Secret Manager-backed env as the main services.
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

      env {
        name  = "SERVICE_NAME"
        value = "tuya-bridge"
      }
      env {
        name  = "PORT"
        value = tostring(var.services["tuya-bridge"].port)
      }
      # DEVICE_SERVICE_URL is added by null_resource.patch_tuya_bridge_url
      # after device-service exists. See lifecycle below — env changes
      # are ignored here so that patch doesn't show as Terraform drift.
    }
  }

  lifecycle {
    ignore_changes = [
      client,
      client_version,
      # See module header: tuya-bridge env is managed by the
      # null_resource patch after create. Future env changes need a
      # `terraform taint null_resource.patch_tuya_bridge_url`.
      template[0].containers[0].env,
    ]
  }
}

# -----------------------------------------------------------------------------
# Post-create patch: DEVICE_SERVICE_URL on tuya-bridge
# -----------------------------------------------------------------------------
# Needs the gcloud CLI on the apply host (same prereq as the registry
# module's docker push). --update-env-vars merges, so the base env set
# at create time is preserved.
#
# replace_triggered_by makes this resource re-run whenever tuya-bridge
# is updated for any other reason (image change, resource-limit change,
# SA change, etc.) — without it, those updates would create a new
# revision from the declared template, which doesn't contain
# DEVICE_SERVICE_URL, silently dropping the URL until someone noticed.
# The dual-revision dance (Terraform creates one, we patch a second
# one on top) is acceptable; the brief window without DEVICE_SERVICE_URL
# is the loop being temporarily idle, not a data integrity issue.
resource "null_resource" "patch_tuya_bridge_url" {
  triggers = {
    tuya_bridge_name   = google_cloud_run_v2_service.tuya_bridge.name
    device_service_uri = google_cloud_run_v2_service.main["device-service"].uri
  }

  lifecycle {
    replace_triggered_by = [google_cloud_run_v2_service.tuya_bridge]
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      echo ">>> Patching DEVICE_SERVICE_URL on ${google_cloud_run_v2_service.tuya_bridge.name}"
      gcloud run services update "${google_cloud_run_v2_service.tuya_bridge.name}" \
        --region="${var.region}" \
        --project="${var.project_id}" \
        --update-env-vars="DEVICE_SERVICE_URL=${google_cloud_run_v2_service.main["device-service"].uri}" \
        --quiet >/dev/null
    EOT
  }
}

# -----------------------------------------------------------------------------
# Invoker IAM
# -----------------------------------------------------------------------------
# Every service (including tuya-bridge) gets allUsers as run.invoker.
# The IAM defense-in-depth on tuya-bridge was reverted in this PR
# because device-service would need to mint Google ID tokens to invoke
# it through Cloud Run IAM — that's a service-code change we deferred.
# tuya-bridge still has app-level auth via INTERNAL_TOKEN, same as
# the AWS deployment where the ALB is public.
resource "google_cloud_run_v2_service_iam_member" "public_main" {
  for_each = google_cloud_run_v2_service.main

  project  = each.value.project
  location = each.value.location
  name     = each.value.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_cloud_run_v2_service_iam_member" "public_tuya_bridge" {
  project  = google_cloud_run_v2_service.tuya_bridge.project
  location = google_cloud_run_v2_service.tuya_bridge.location
  name     = google_cloud_run_v2_service.tuya_bridge.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
