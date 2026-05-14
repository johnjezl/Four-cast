# =============================================================================
# Azure Database for PostgreSQL Flexible Server Module
# =============================================================================
# Public network access is enabled for the class/demo shape. The
# firewall rule with 0.0.0.0 mirrors Azure's "allow Azure services"
# behavior so Container Apps can reach the server without a VNet.
#
# First-apply note: the three `tcp_keepalives_*` server parameters are
# static parameters, so each one triggers a server restart at create
# time (~3-5 min total). They're applied via `az` CLI in a
# null_resource rather than as `azurerm_postgresql_flexible_server_
# configuration` resources, because the latter form makes destroy
# pay the same restart cost in reverse for each parameter (~30 min
# total) — see the comment on null_resource.tcp_keepalives below.
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

  # Default delete timeout is 30 min. Bump for safety because the
  # firewall-rule delete can be queued behind other server-scoped
  # operations and the polling deadline expires before Azure
  # acknowledges completion — even when the rule actually deleted.
  # 60 min absorbs that.
  timeouts {
    delete = "60m"
  }
}

# Aggressive TCP keepalives so Postgres detects dead sessions quickly.
# Defaults (tcp_keepalives_idle = 7200s / 2h) let Container Apps
# teardowns leave orphaned sessions in pg_stat_activity for hours.
# With these the server reaps a dead session in ~90s
# (60s idle + 3 × 10s probes).
#
# Set via az CLI rather than three separate
# `azurerm_postgresql_flexible_server_configuration` resources. Reason:
# each configuration resource is a server-static parameter, and Azure
# restarts the Flexible Server to apply it both on create AND on revert
# during destroy. Three of them sequentially destroying = ~30 minutes
# tacked onto every `terraform destroy` (verified in the field).
# Moving them to a null_resource means the values are still set at
# create time, the same restart cost is paid up front, but terraform
# doesn't try to revert them on destroy — the server takes them with
# it when it's destroyed.
resource "null_resource" "tcp_keepalives" {
  triggers = {
    server_name         = azurerm_postgresql_flexible_server.main.name
    resource_group_name = var.resource_group_name
    # Re-fire if any value changes.
    idle     = "60"
    interval = "10"
    probes   = "3"
  }

  # Static-parameter changes restart the Flexible Server asynchronously,
  # and the next `az parameter set` call against a still-restarting
  # server fails with ServerIsBusy. Wait for the server's state to
  # return to "Ready" between calls. `az` returns from `parameter set`
  # once the API accepts the change, NOT once the restart completes —
  # so the explicit wait loop is required.
  provisioner "local-exec" {
    command = <<-EOT
      set -e
      SERVER='${self.triggers.server_name}'
      RG='${self.triggers.resource_group_name}'

      wait_for_ready() {
        for _ in $(seq 1 60); do
          state=$(az postgres flexible-server show --name "$SERVER" --resource-group "$RG" --query state -o tsv 2>/dev/null || echo "")
          if [ "$state" = "Ready" ]; then
            return 0
          fi
          sleep 10
        done
        echo "ERROR: server $SERVER did not return to Ready within 10 minutes (last state: $state)" >&2
        return 1
      }

      wait_for_ready
      az postgres flexible-server parameter set \
        --server-name "$SERVER" --resource-group "$RG" \
        --name tcp_keepalives_idle --value '${self.triggers.idle}'

      wait_for_ready
      az postgres flexible-server parameter set \
        --server-name "$SERVER" --resource-group "$RG" \
        --name tcp_keepalives_interval --value '${self.triggers.interval}'

      wait_for_ready
      az postgres flexible-server parameter set \
        --server-name "$SERVER" --resource-group "$RG" \
        --name tcp_keepalives_count --value '${self.triggers.probes}'

      wait_for_ready
    EOT
  }
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
#
# The `wait_for_ready` loop after the restart is load-bearing: `az
# restart` returns once the API accepts the call, not once the server
# is back to Ready (same gotcha PR #38 fixed for parameter sets). If
# this resource's destroy returns before the server is actually Ready,
# the next operations to fire (database delete + firewall_rule delete)
# hit a still-restarting server and either fail with ServerIsBusy or
# wedge in azurerm's polling loop until the 60m deadline. The
# `depends_on` list below includes the firewall rule for the same
# reason — without it, firewall_rule.destroy races this restart in
# parallel and hits the same wedge.
resource "null_resource" "terminate_db_connections" {
  triggers = {
    server_name         = azurerm_postgresql_flexible_server.main.name
    resource_group_name = var.resource_group_name
  }

  # All server-scoped children (database, firewall rule, tcp_keepalives
  # null_resource) destroy after the restart fires and the server
  # returns to Ready. Reverses to create-time:
  # server → tcp_keepalives → database → firewall_rule → this.
  depends_on = [
    azurerm_postgresql_flexible_server_database.main,
    azurerm_postgresql_flexible_server_firewall_rule.azure_services,
    null_resource.tcp_keepalives,
  ]

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set -e
      SERVER='${self.triggers.server_name}'
      RG='${self.triggers.resource_group_name}'

      wait_for_ready() {
        for _ in $(seq 1 60); do
          state=$(az postgres flexible-server show --name "$SERVER" --resource-group "$RG" --query state -o tsv 2>/dev/null || echo "")
          if [ "$state" = "Ready" ]; then
            return 0
          fi
          sleep 10
        done
        echo "ERROR: server $SERVER did not return to Ready within 10 minutes (last state: $state)" >&2
        return 1
      }

      az postgres flexible-server restart --name "$SERVER" --resource-group "$RG"
      wait_for_ready
    EOT
  }
}

output "fqdn" {
  value = azurerm_postgresql_flexible_server.main.fqdn
}

output "db_name" {
  value = azurerm_postgresql_flexible_server_database.main.name
}
