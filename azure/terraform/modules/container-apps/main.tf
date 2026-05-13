# =============================================================================
# Container Apps Module
# =============================================================================
# Three resource blocks for the five services:
#   - azurerm_container_app.main: automation, user, analytics
#   - azurerm_container_app.device_service: split out because analytics
#     and tuya-bridge need to reference its URL
#   - azurerm_container_app.tuya_bridge: split out because
#     DEVICE_SERVICE_URL is patched in after create
# =============================================================================

locals {
  azure_name_prefix = "sh-${substr(var.environment, 0, 4)}"
}

# -----------------------------------------------------------------------------
# Per-service managed identities
# -----------------------------------------------------------------------------
resource "azurerm_user_assigned_identity" "services" {
  for_each = var.services

  name                = "${local.azure_name_prefix}-${replace(each.key, "-service", "")}-id"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# Pull images from the private ACR.
resource "azurerm_role_assignment" "acr_pull" {
  for_each = var.services

  scope                = var.registry_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.services[each.key].principal_id
}

# Every service needs the shared app secrets, but the Tuya credential
# secret is granted only to tuya-bridge below. Iterate var.services (static
# keys) and look up principal_ids by key so for_each is resolvable before
# the identity resources exist — required for `terraform import`.
locals {
  app_secret_grants = flatten([
    for service_key, _ in var.services : [
      {
        key          = "${service_key}-jwt"
        principal_id = azurerm_user_assigned_identity.services[service_key].principal_id
        scope        = var.jwt_secret_scope
      },
      {
        key          = "${service_key}-internal"
        principal_id = azurerm_user_assigned_identity.services[service_key].principal_id
        scope        = var.internal_token_scope
      },
    ]
  ])
}

resource "azurerm_role_assignment" "app_secrets" {
  for_each = { for grant in local.app_secret_grants : grant.key => grant }

  scope                = each.value.scope
  role_definition_name = "Key Vault Secrets User"
  principal_id         = each.value.principal_id
}

resource "azurerm_role_assignment" "tuya_bridge_secret" {
  scope                = var.tuya_secret_scope
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.services["tuya-bridge"].principal_id
}

# Least-privilege Service Bus data-plane roles.
resource "azurerm_role_assignment" "device_service_sender" {
  scope                = var.servicebus_queue_id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = azurerm_user_assigned_identity.services["device-service"].principal_id
}

resource "azurerm_role_assignment" "analytics_service_receiver" {
  scope                = var.servicebus_queue_id
  role_definition_name = "Azure Service Bus Data Receiver"
  principal_id         = azurerm_user_assigned_identity.services["analytics-service"].principal_id
}

# -----------------------------------------------------------------------------
# Container Apps environment
# -----------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "main" {
  name                = "${local.azure_name_prefix}-logs"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

resource "azurerm_container_app_environment" "main" {
  name                       = "${local.azure_name_prefix}-apps"
  location                   = var.location
  resource_group_name        = var.resource_group_name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
  tags                       = var.tags
}

# -----------------------------------------------------------------------------
# Shared template config
# -----------------------------------------------------------------------------
locals {
  base_env = [
    { name = "CLOUD_PROVIDER", value = "azure" },
    { name = "AZURE_KEY_VAULT_URL", value = var.key_vault_url },
    { name = "AZURE_SERVICEBUS_FULLY_QUALIFIED_NAMESPACE", value = var.servicebus_namespace_fqdn },
    { name = "SERVICEBUS_QUEUE", value = var.servicebus_queue_name },
    { name = "SERVICEBUS_DLQ_QUEUE", value = var.servicebus_dlq_name },
    { name = "SECRET_NAME", value = var.tuya_secret_name },
    { name = "ENVIRONMENT", value = var.environment },
    { name = "LOG_LEVEL", value = var.log_level },
    { name = "DATABASE_URL", value = "postgresql+asyncpg://${var.db_username}:${var.db_password}@${var.db_host}:5432/${var.db_name}?ssl=require" },
    { name = "TUYA_DEVICE_IDS", value = var.tuya_device_ids },
  ]
}

# -----------------------------------------------------------------------------
# Container Apps (automation, user, analytics)
# -----------------------------------------------------------------------------
resource "azurerm_container_app" "main" {
  for_each = { for k, v in var.services : k => v if k != "tuya-bridge" && k != "device-service" }

  name                         = "${local.azure_name_prefix}-${each.key}"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = var.resource_group_name
  revision_mode                = "Single"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.services[each.key].id]
  }

  registry {
    server   = var.registry_login_server
    identity = azurerm_user_assigned_identity.services[each.key].id
  }

  secret {
    name                = "jwt-secret"
    key_vault_secret_id = var.jwt_secret_id
    identity            = azurerm_user_assigned_identity.services[each.key].id
  }

  secret {
    name                = "internal-token"
    key_vault_secret_id = var.internal_token_id
    identity            = azurerm_user_assigned_identity.services[each.key].id
  }

  ingress {
    external_enabled           = true
    target_port                = each.value.port
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
      name   = replace(each.key, "-", "")
      image  = var.image_urls[each.key]
      cpu    = each.value.cpu
      memory = each.value.memory

      startup_probe {
        path                    = "/health"
        port                    = each.value.port
        transport               = "HTTP"
        initial_delay           = 10
        interval_seconds        = 10
        timeout                 = 5
        failure_count_threshold = 6
      }

      liveness_probe {
        path                    = "/health"
        port                    = each.value.port
        transport               = "HTTP"
        interval_seconds        = 30
        timeout                 = 5
        failure_count_threshold = 3
      }

      dynamic "env" {
        for_each = local.base_env
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

      env {
        name  = "SERVICE_NAME"
        value = each.key
      }

      env {
        name  = "PORT"
        value = tostring(each.value.port)
      }

      env {
        name  = "AZURE_CLIENT_ID"
        value = azurerm_user_assigned_identity.services[each.key].client_id
      }

      # analytics-service queries device-service for live counts;
      # automation-service issues device commands as part of rule
      # execution (e.g., the /chase demo endpoint). Same shape as the
      # equivalent dynamic block in gcp/terraform/modules/cloud-run/main.tf.
      dynamic "env" {
        for_each = contains(["analytics-service", "automation-service"], each.key) ? ["https://${azurerm_container_app.device_service.ingress[0].fqdn}"] : []
        content {
          name  = "DEVICE_SERVICE_URL"
          value = env.value
        }
      }
    }
  }

  depends_on = [
    azurerm_role_assignment.acr_pull,
    azurerm_role_assignment.app_secrets,
    azurerm_role_assignment.device_service_sender,
    azurerm_role_assignment.analytics_service_receiver,
  ]
}

# -----------------------------------------------------------------------------
# Container App: device-service (split out because analytics + tuya-bridge
# both need to reference its URL cross-resource)
# -----------------------------------------------------------------------------
resource "azurerm_container_app" "device_service" {
  name                         = "${local.azure_name_prefix}-device-service"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = var.resource_group_name
  revision_mode                = "Single"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.services["device-service"].id]
  }

  registry {
    server   = var.registry_login_server
    identity = azurerm_user_assigned_identity.services["device-service"].id
  }

  secret {
    name                = "jwt-secret"
    key_vault_secret_id = var.jwt_secret_id
    identity            = azurerm_user_assigned_identity.services["device-service"].id
  }

  secret {
    name                = "internal-token"
    key_vault_secret_id = var.internal_token_id
    identity            = azurerm_user_assigned_identity.services["device-service"].id
  }

  ingress {
    external_enabled           = true
    target_port                = var.services["device-service"].port
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
      name   = "deviceservice"
      image  = var.image_urls["device-service"]
      cpu    = var.services["device-service"].cpu
      memory = var.services["device-service"].memory

      startup_probe {
        path                    = "/health"
        port                    = var.services["device-service"].port
        transport               = "HTTP"
        initial_delay           = 10
        interval_seconds        = 10
        timeout                 = 5
        failure_count_threshold = 6
      }

      liveness_probe {
        path                    = "/health"
        port                    = var.services["device-service"].port
        transport               = "HTTP"
        interval_seconds        = 30
        timeout                 = 5
        failure_count_threshold = 3
      }

      dynamic "env" {
        for_each = local.base_env
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

      env {
        name  = "SERVICE_NAME"
        value = "device-service"
      }

      env {
        name  = "PORT"
        value = tostring(var.services["device-service"].port)
      }

      env {
        name  = "AZURE_CLIENT_ID"
        value = azurerm_user_assigned_identity.services["device-service"].client_id
      }

      env {
        name  = "TUYA_BRIDGE_URL"
        value = "https://${azurerm_container_app.tuya_bridge.ingress[0].fqdn}"
      }
    }
  }

  depends_on = [
    azurerm_role_assignment.acr_pull,
    azurerm_role_assignment.app_secrets,
    azurerm_role_assignment.device_service_sender,
  ]
}

# -----------------------------------------------------------------------------
# Container App: tuya-bridge (split out for the env cycle break)
# -----------------------------------------------------------------------------
resource "azurerm_container_app" "tuya_bridge" {
  name                         = "${local.azure_name_prefix}-tuya-bridge"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = var.resource_group_name
  revision_mode                = "Single"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.services["tuya-bridge"].id]
  }

  registry {
    server   = var.registry_login_server
    identity = azurerm_user_assigned_identity.services["tuya-bridge"].id
  }

  secret {
    name                = "jwt-secret"
    key_vault_secret_id = var.jwt_secret_id
    identity            = azurerm_user_assigned_identity.services["tuya-bridge"].id
  }

  secret {
    name                = "internal-token"
    key_vault_secret_id = var.internal_token_id
    identity            = azurerm_user_assigned_identity.services["tuya-bridge"].id
  }

  ingress {
    external_enabled           = true
    target_port                = var.services["tuya-bridge"].port
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
      name   = "tuyabridge"
      image  = var.image_urls["tuya-bridge"]
      cpu    = var.services["tuya-bridge"].cpu
      memory = var.services["tuya-bridge"].memory

      startup_probe {
        path                    = "/health"
        port                    = var.services["tuya-bridge"].port
        transport               = "HTTP"
        initial_delay           = 10
        interval_seconds        = 10
        timeout                 = 5
        failure_count_threshold = 6
      }

      liveness_probe {
        path                    = "/health"
        port                    = var.services["tuya-bridge"].port
        transport               = "HTTP"
        interval_seconds        = 30
        timeout                 = 5
        failure_count_threshold = 3
      }

      dynamic "env" {
        for_each = local.base_env
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

      env {
        name  = "SERVICE_NAME"
        value = "tuya-bridge"
      }

      env {
        name  = "PORT"
        value = tostring(var.services["tuya-bridge"].port)
      }

      env {
        name  = "AZURE_CLIENT_ID"
        value = azurerm_user_assigned_identity.services["tuya-bridge"].client_id
      }
      # DEVICE_SERVICE_URL is added by null_resource.patch_tuya_bridge_url
      # after device-service exists.
    }
  }

  depends_on = [
    azurerm_role_assignment.acr_pull,
    azurerm_role_assignment.app_secrets,
    azurerm_role_assignment.tuya_bridge_secret,
  ]

  lifecycle {
    ignore_changes = [
      # See module header: tuya-bridge env is patched after create.
      # Future env changes need a `terraform taint null_resource.patch_tuya_bridge_url`.
      template[0].container[0].env,
    ]
  }
}

# -----------------------------------------------------------------------------
# Post-create patch: DEVICE_SERVICE_URL on tuya-bridge
# -----------------------------------------------------------------------------
resource "null_resource" "patch_tuya_bridge_url" {
  triggers = {
    tuya_bridge_name   = azurerm_container_app.tuya_bridge.name
    device_service_url = "https://${azurerm_container_app.device_service.ingress[0].fqdn}"
  }

  lifecycle {
    replace_triggered_by = [azurerm_container_app.tuya_bridge]
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      echo ">>> Patching DEVICE_SERVICE_URL on ${azurerm_container_app.tuya_bridge.name}"
      az containerapp update \
        --name "${azurerm_container_app.tuya_bridge.name}" \
        --resource-group "${var.resource_group_name}" \
        --set-env-vars "DEVICE_SERVICE_URL=https://${azurerm_container_app.device_service.ingress[0].fqdn}" \
        >/dev/null
    EOT
  }
}
