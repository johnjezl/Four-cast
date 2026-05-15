# =============================================================================
# Azure per-service sub-module
# =============================================================================
# One Container App + its managed identity + RBAC bindings + (optional)
# Service Bus role + (optional) Tuya secret access. Instantiated three
# ways from the parent module (../main.tf) to break the cross-service
# URL cycle, same pattern as gcp/terraform/modules/service/.
#
# Templating: env vars are rendered via templatefile() from
# templates/env.json.tftpl → jsondecode() → dynamic env block. Native
# secret-backed envs (jwt-secret, internal-token) stay as plain HCL
# blocks since they reference Key Vault secret names that the
# containerapp `secret {}` block defines separately.
#
# Two-resource-block workaround for lifecycle.ignore_changes:
# Terraform's lifecycle meta-argument is static, so to conditionally
# ignore env drift we gate two near-identical azurerm_container_app
# resources by `count` on var.ignore_env_changes. Mirrors the GCP
# module's `default` / `env_ignored` split.
# =============================================================================

# -----------------------------------------------------------------------------
# Managed identity for this service
# -----------------------------------------------------------------------------
resource "azurerm_user_assigned_identity" "this" {
  name                = "${var.azure_name_prefix}-${replace(var.service_name, "-service", "")}-id"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# -----------------------------------------------------------------------------
# Universal role assignments (every service needs these)
# -----------------------------------------------------------------------------
resource "azurerm_role_assignment" "acr_pull" {
  scope                = var.registry_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

resource "azurerm_role_assignment" "jwt_secret" {
  scope                = var.jwt_secret_scope
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

resource "azurerm_role_assignment" "internal_token" {
  scope                = var.internal_token_scope
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

# -----------------------------------------------------------------------------
# Optional role assignments
# -----------------------------------------------------------------------------
# Tuya secret access — only the tuya-bridge instance enables this.
resource "azurerm_role_assignment" "tuya_secret" {
  count = var.grant_tuya_secret_access ? 1 : 0

  scope                = var.tuya_secret_scope
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

# Service Bus — sender for device-service, receiver for analytics-service.
# Putting these inside the module (rather than at parent level) means the
# Container App resource below can depend_on the role assignment directly,
# avoiding the IAM-before-revision-start race that GCP also hit.
locals {
  servicebus_role_name = {
    sender   = "Azure Service Bus Data Sender"
    receiver = "Azure Service Bus Data Receiver"
  }
}

resource "azurerm_role_assignment" "servicebus" {
  count = var.servicebus_role == "none" ? 0 : 1

  scope                = var.servicebus_queue_id
  role_definition_name = local.servicebus_role_name[var.servicebus_role]
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

# -----------------------------------------------------------------------------
# Templated env-var list
# -----------------------------------------------------------------------------
locals {
  database_url = "postgresql+asyncpg://${var.db_username}:${var.db_password}@${var.db_host}:5432/${var.db_name}?ssl=require"

  env_vars = jsondecode(templatefile("${path.module}/templates/env.json.tftpl", {
    service_name              = var.service_name
    port                      = tostring(var.port)
    key_vault_url             = var.key_vault_url
    servicebus_namespace_fqdn = var.servicebus_namespace_fqdn
    servicebus_queue_name     = var.servicebus_queue_name
    servicebus_dlq_name       = var.servicebus_dlq_name
    tuya_secret_name          = var.tuya_secret_name
    environment               = var.environment
    log_level                 = var.log_level
    database_url              = local.database_url
    tuya_device_ids           = var.tuya_device_ids
    azure_client_id           = azurerm_user_assigned_identity.this.client_id
    device_service_url        = var.device_service_url
    tuya_bridge_url           = var.tuya_bridge_url
  }))

  # Container Apps container name allows [a-z0-9-] only, no underscores
  # or capitals. Strip dashes from the service name for the inner name.
  container_name = replace(var.service_name, "-", "")
}

# -----------------------------------------------------------------------------
# Container App (default lifecycle)
# -----------------------------------------------------------------------------
resource "azurerm_container_app" "default" {
  count = var.ignore_env_changes ? 0 : 1

  name                         = "${var.azure_name_prefix}-${var.service_name}"
  container_app_environment_id = var.container_app_environment_id
  resource_group_name          = var.resource_group_name
  revision_mode                = "Single"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.this.id]
  }

  registry {
    server   = var.registry_login_server
    identity = azurerm_user_assigned_identity.this.id
  }

  secret {
    name                = "jwt-secret"
    key_vault_secret_id = var.jwt_secret_id
    identity            = azurerm_user_assigned_identity.this.id
  }

  secret {
    name                = "internal-token"
    key_vault_secret_id = var.internal_token_id
    identity            = azurerm_user_assigned_identity.this.id
  }

  ingress {
    external_enabled           = true
    target_port                = var.port
    transport                  = "http"
    allow_insecure_connections = false

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.min_instances
    max_replicas = var.max_instances

    container {
      name   = local.container_name
      image  = var.image_url
      cpu    = var.cpu
      memory = var.memory

      # 10s delay + 10 × 10s = 110s total budget to come up. Mirrors
      # the GCP per-service module's budget. FastAPI cold start +
      # first Key Vault secret fetch + Postgres Flexible Server first
      # handshake normally lands well under this, but fresh-apply tail
      # latency on a cold registry pull + just-propagated RBAC has been
      # seen to land at the previous 70s ceiling. failure_count_threshold
      # only widens the budget on *failed* probes; healthy starts still
      # mark Ready as soon as the first 200 OK lands.
      startup_probe {
        path                    = "/health"
        port                    = var.port
        transport               = "HTTP"
        initial_delay           = 10
        interval_seconds        = 10
        timeout                 = 5
        failure_count_threshold = 10
      }

      liveness_probe {
        path                    = "/health"
        port                    = var.port
        transport               = "HTTP"
        interval_seconds        = 30
        timeout                 = 5
        failure_count_threshold = 3
      }

      dynamic "env" {
        for_each = local.env_vars
        content {
          name  = env.value.name
          value = env.value.value
        }
      }

      # Key Vault-backed envs reference the secrets defined on the
      # container app (above). Plain env entries carry `value`,
      # secret-backed entries carry `secret_name` — never both.
      env {
        name        = "JWT_SECRET"
        secret_name = "jwt-secret"
      }

      env {
        name        = "INTERNAL_TOKEN"
        secret_name = "internal-token"
      }
    }
  }

  depends_on = [
    azurerm_role_assignment.acr_pull,
    azurerm_role_assignment.jwt_secret,
    azurerm_role_assignment.internal_token,
    azurerm_role_assignment.tuya_secret,
    azurerm_role_assignment.servicebus,
  ]
}

# -----------------------------------------------------------------------------
# Container App (env drift ignored — tuya-bridge flavor)
# -----------------------------------------------------------------------------
resource "azurerm_container_app" "env_ignored" {
  count = var.ignore_env_changes ? 1 : 0

  name                         = "${var.azure_name_prefix}-${var.service_name}"
  container_app_environment_id = var.container_app_environment_id
  resource_group_name          = var.resource_group_name
  revision_mode                = "Single"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.this.id]
  }

  registry {
    server   = var.registry_login_server
    identity = azurerm_user_assigned_identity.this.id
  }

  secret {
    name                = "jwt-secret"
    key_vault_secret_id = var.jwt_secret_id
    identity            = azurerm_user_assigned_identity.this.id
  }

  secret {
    name                = "internal-token"
    key_vault_secret_id = var.internal_token_id
    identity            = azurerm_user_assigned_identity.this.id
  }

  ingress {
    external_enabled           = true
    target_port                = var.port
    transport                  = "http"
    allow_insecure_connections = false

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.min_instances
    max_replicas = var.max_instances

    container {
      name   = local.container_name
      image  = var.image_url
      cpu    = var.cpu
      memory = var.memory

      # See startup_probe comment in the `default` block above for the
      # 110s budget rationale. Same body, kept in sync.
      startup_probe {
        path                    = "/health"
        port                    = var.port
        transport               = "HTTP"
        initial_delay           = 10
        interval_seconds        = 10
        timeout                 = 5
        failure_count_threshold = 10
      }

      liveness_probe {
        path                    = "/health"
        port                    = var.port
        transport               = "HTTP"
        interval_seconds        = 30
        timeout                 = 5
        failure_count_threshold = 3
      }

      dynamic "env" {
        for_each = local.env_vars
        content {
          name  = env.value.name
          value = env.value.value
        }
      }

      env {
        name        = "JWT_SECRET"
        secret_name = "jwt-secret"
      }

      env {
        name        = "INTERNAL_TOKEN"
        secret_name = "internal-token"
      }
    }
  }

  depends_on = [
    azurerm_role_assignment.acr_pull,
    azurerm_role_assignment.jwt_secret,
    azurerm_role_assignment.internal_token,
    azurerm_role_assignment.tuya_secret,
    azurerm_role_assignment.servicebus,
  ]

  lifecycle {
    ignore_changes = [
      # env list is patched post-create by the parent-level
      # null_resource.patch_tuya_bridge_url. Subsequent Terraform plans
      # would otherwise re-render the env from the declared template
      # (no DEVICE_SERVICE_URL) and silently overwrite the patch on
      # the next apply.
      template[0].container[0].env,
    ]
  }
}

# Convenience selector — only one of the two resources is ever instantiated.
locals {
  container_app = var.ignore_env_changes ? azurerm_container_app.env_ignored[0] : azurerm_container_app.default[0]
}
