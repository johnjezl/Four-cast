# =============================================================================
# Azure Database for PostgreSQL Flexible Server Module
# =============================================================================
# Public network access is enabled for the class/demo shape. The
# firewall rule with 0.0.0.0 mirrors Azure's "allow Azure services"
# behavior so Container Apps can reach the server without a VNet.
#
# First-apply note: the three `tcp_keepalives_*` server parameters are
# static parameters, so each one triggers a server restart at create
# time. Expect ~60-90s extra on first apply for the parameter changes
# to land. Subsequent applies are no-ops unless the values change.
# =============================================================================

resource "azurerm_postgresql_flexible_server" "main" {
  name                          = "${var.name_prefix}-pg-${var.unique_suffix}"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  version                       = "15"
  administrator_login           = var.db_username
  administrator_password        = var.db_password
  public_network_access_enabled = true
  storage_mb                    = 32768
  sku_name                      = "B_Standard_B1ms"
  backup_retention_days         = 7
  geo_redundant_backup_enabled  = false
  tags                          = var.tags

  # Azure auto-assigns an availability zone at creation; without this,
  # every subsequent `terraform plan` sees `zone = "<N>" -> null` drift
  # and the apply would attempt a zone change (recreate on some SKUs).
  lifecycle {
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_database" "main" {
  name      = "smarthome"
  server_id = azurerm_postgresql_flexible_server.main.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# 0.0.0.0/0.0.0.0 is Azure's idiom for "allow connections from any Azure
# service" — every Container Apps environment in every Azure tenant can
# reach this server on port 5432. The strong random db_password is the
# only barrier. Acceptable for the demo / class shape; for production,
# replace with VNet-integrated Container Apps + Private Endpoint Postgres
# (see "demo shape vs. production shape" in azure/README.md).
resource "azurerm_postgresql_flexible_server_firewall_rule" "azure_services" {
  name             = "allow-azure-services"
  server_id        = azurerm_postgresql_flexible_server.main.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

# Aggressive TCP keepalives so Postgres detects dead sessions quickly.
# Defaults (tcp_keepalives_idle = 7200s / 2h) let Container Apps
# teardowns leave orphaned sessions in pg_stat_activity for hours,
# which blocks `DROP DATABASE` on destroy. With these the server reaps
# a dead session in ~90s (60s idle + 3 × 10s probes). Helpful for
# normal-operation disconnects (dev-machine network blips, scaled-down
# containers); not sufficient alone to make destroy reliable — see the
# restart null_resource below.
resource "azurerm_postgresql_flexible_server_configuration" "tcp_keepalives_idle" {
  name      = "tcp_keepalives_idle"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = "60"
}

resource "azurerm_postgresql_flexible_server_configuration" "tcp_keepalives_interval" {
  name      = "tcp_keepalives_interval"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = "10"
}

resource "azurerm_postgresql_flexible_server_configuration" "tcp_keepalives_count" {
  name      = "tcp_keepalives_count"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = "3"
}

# Force-kill any lingering Postgres sessions immediately before the
# database is dropped, by restarting the Flexible Server. The GCP port
# proved that three milder approaches all fail in practice:
#   - time_sleep alone (any duration up to 180s)
#   - aggressive tcp_keepalives_* on the instance
#   - both combined
# The root cause is that Container Apps can leave sessions in
# pg_stat_activity that neither Postgres nor the kernel reap inside any
# reasonable destroy window. A server restart is the blunt-but-reliable
# nuclear option: ~30s, kills every session, and nothing reconnects
# because the compute layer is already gone by the time this fires
# (graph order: container_apps → time_sleep[implicit] → this → database
# → server).
#
# `triggers` captures the server identity at create time so it's still
# available during destroy when the resource is being removed.
#
# Note: `az postgres flexible-server restart` doesn't accept `--yes` (no
# confirmation prompt to suppress). Don't add one — it errors with
# `unrecognized arguments: --yes` and halts the destroy mid-flight.
resource "null_resource" "terminate_db_connections" {
  triggers = {
    server_name         = azurerm_postgresql_flexible_server.main.name
    resource_group_name = var.resource_group_name
  }

  # All server-scoped children (database + configurations) destroy before
  # the restart fires. Reverses to create-time: server → configurations →
  # database → this. Without configs in depends_on, terraform could
  # destroy them in parallel with the restart — harmless but graph-untidy.
  depends_on = [
    azurerm_postgresql_flexible_server_database.main,
    azurerm_postgresql_flexible_server_configuration.tcp_keepalives_idle,
    azurerm_postgresql_flexible_server_configuration.tcp_keepalives_interval,
    azurerm_postgresql_flexible_server_configuration.tcp_keepalives_count,
  ]

  provisioner "local-exec" {
    when    = destroy
    command = "az postgres flexible-server restart --name ${self.triggers.server_name} --resource-group ${self.triggers.resource_group_name}"
  }
}

output "fqdn" {
  value = azurerm_postgresql_flexible_server.main.fqdn
}

output "db_name" {
  value = azurerm_postgresql_flexible_server_database.main.name
}
