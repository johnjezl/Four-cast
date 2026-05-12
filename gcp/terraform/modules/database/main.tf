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
  }
}

resource "google_sql_database" "main" {
  name     = "smarthome"
  instance = google_sql_database_instance.main.name
}

resource "google_sql_user" "main" {
  name     = var.db_username
  instance = google_sql_database_instance.main.name
  password = var.db_password
}

output "connection_name" {
  description = "Cloud SQL connection name in <project>:<region>:<instance> form. Pass to Cloud Run as cloud_sql_instance and use as ?host=/cloudsql/<connection-name> in DATABASE_URL."
  value       = google_sql_database_instance.main.connection_name
}

output "db_name" {
  value = google_sql_database.main.name
}
