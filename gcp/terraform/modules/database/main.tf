# =============================================================================
# Cloud SQL (PostgreSQL) Module
# =============================================================================
# db-f1-micro keeps this in or near the free tier for short-lived demo
# instances. Public IP is enabled because Cloud Run reaches the instance
# via the Cloud SQL Auth Proxy, which works over the public endpoint
# without needing a Serverless VPC Connector.
#
# Auth Proxy + IAM-authenticated client (per-service SAs granted
# roles/cloudsql.client by the Cloud Run module) is what gates access —
# no SG/firewall rules required.
# =============================================================================

resource "google_sql_database_instance" "main" {
  name             = "${var.name_prefix}-postgres"
  database_version = "POSTGRES_15"
  region           = var.region

  deletion_protection = false

  settings {
    tier              = "db-f1-micro"
    availability_type = "ZONAL"
    disk_size         = 10
    disk_type         = "PD_HDD"

    backup_configuration {
      enabled = false
    }

    ip_configuration {
      ipv4_enabled = true
      # No authorized_networks: access is gated by the Cloud SQL Auth
      # Proxy + IAM on the runtime service accounts.
    }

    # Aggressive TCP keepalives so Postgres detects dead sessions
    # quickly. The default tcp_keepalives_idle is 7200s (2 hours), so
    # when Cloud Run tears down its containers without a clean FIN,
    # the orphaned sessions linger in pg_stat_activity for hours and
    # block `DROP DATABASE` on destroy. With these settings Postgres
    # reaps a dead session in ~90s (60s idle + 3 × 10s probes).
    database_flags {
      name  = "tcp_keepalives_idle"
      value = "60"
    }
    database_flags {
      name  = "tcp_keepalives_interval"
      value = "10"
    }
    database_flags {
      name  = "tcp_keepalives_count"
      value = "3"
    }
  }
}

resource "google_sql_user" "main" {
  name     = var.db_username
  instance = google_sql_database_instance.main.name
  password = var.db_password
}

# `depends_on` flips create order to user → database, which gives the
# inverse on destroy: database drops first, then user. Postgres refuses
# to drop a role that still owns objects, so dropping the database (and
# its schema objects with it) before the user is what makes the user
# drop succeed in one pass. Without this the two destroys run in
# parallel and race.
resource "google_sql_database" "main" {
  name     = "smarthome"
  instance = google_sql_database_instance.main.name

  depends_on = [google_sql_user.main]
}

# Force-kill any lingering Postgres sessions immediately before the
# database is dropped, by restarting the Cloud SQL instance. Three
# milder approaches all failed in practice on the GCP port:
#   - time_sleep alone (any duration up to 180s)
#   - aggressive tcp_keepalives_* on the instance
#   - both combined
# The root cause is that Cloud Run can leave sessions in
# pg_stat_activity that neither Postgres nor the kernel reap inside any
# reasonable destroy window. A restart is the blunt-but-reliable
# nuclear option: ~30s, kills every session, and nothing reconnects
# because Cloud Run is already gone by the time this fires (graph
# order: cloud_run → time_sleep → this → database → user → instance).
#
# `triggers` captures the instance identity at create time so it's
# still available during destroy when the resource is being removed.
resource "null_resource" "terminate_db_connections" {
  triggers = {
    instance_name = google_sql_database_instance.main.name
    project       = google_sql_database_instance.main.project
  }

  depends_on = [google_sql_database.main]

  provisioner "local-exec" {
    when    = destroy
    command = "gcloud sql instances restart ${self.triggers.instance_name} --project=${self.triggers.project} --quiet"
  }
}

output "connection_name" {
  description = "Cloud SQL connection name in <project>:<region>:<instance> form. Pass to Cloud Run as cloud_sql_instance and use as ?host=/cloudsql/<connection-name> in DATABASE_URL."
  value       = google_sql_database_instance.main.connection_name
}

output "db_name" {
  value = google_sql_database.main.name
}
