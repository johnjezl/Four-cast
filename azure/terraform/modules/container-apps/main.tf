# =============================================================================
# Azure Container Apps module
# =============================================================================
# Thin wrapper: owns the shared Container Apps environment + Log Analytics
# workspace, then calls ./service three ways for the five microservices.
# The per-service detail (managed identity, RBAC, Container App, env
# templating) lives in the sub-module — see ./service/main.tf.
#
# The three-way call pattern (singleton tuya_bridge / singleton
# device_service / for_each over the middle three) matches gcp/terraform.
# It's forced by Terraform's self-referential-block check: a `for_each`
# instance can't reference another instance of the same module at
# create time, so any service that's the target of a cross-reference
# must live in its own module call.
# =============================================================================

locals {
  azure_name_prefix = "sh-${substr(var.environment, 0, 4)}"
}

# -----------------------------------------------------------------------------
# Container Apps environment + Log Analytics workspace
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
# Per-service sub-module calls
# -----------------------------------------------------------------------------
# Common inputs factored into local.service_common to keep the three
# call sites readable. The cross-service URL inputs (device_service_url,
# tuya_bridge_url, ignore_env_changes) differ per call.
locals {
  service_common = {
    azure_name_prefix            = local.azure_name_prefix
    environment                  = var.environment
    log_level                    = var.log_level
    resource_group_name          = var.resource_group_name
    location                     = var.location
    tags                         = var.tags
    container_app_environment_id = azurerm_container_app_environment.main.id
    registry_id                  = var.registry_id
    registry_login_server        = var.registry_login_server
    min_instances                = var.min_instances
    max_instances                = var.max_instances

    db_host     = var.db_host
    db_name     = var.db_name
    db_username = var.db_username
    db_password = var.db_password

    key_vault_url        = var.key_vault_url
    jwt_secret_id        = var.jwt_secret_id
    jwt_secret_scope     = var.jwt_secret_scope
    internal_token_id    = var.internal_token_id
    internal_token_scope = var.internal_token_scope
    tuya_secret_id       = var.tuya_secret_id
    tuya_secret_scope    = var.tuya_secret_scope
    tuya_secret_name     = var.tuya_secret_name
    tuya_device_ids      = var.tuya_device_ids

    servicebus_namespace_fqdn = var.servicebus_namespace_fqdn
    servicebus_queue_name     = var.servicebus_queue_name
    servicebus_queue_id       = var.servicebus_queue_id
    servicebus_dlq_name       = var.servicebus_dlq_name
  }
}

module "tuya_bridge" {
  source = "./service"

  service_name = "tuya-bridge"
  port         = var.services["tuya-bridge"].port
  cpu          = var.services["tuya-bridge"].cpu
  memory       = var.services["tuya-bridge"].memory
  image_url    = var.image_urls["tuya-bridge"]

  azure_name_prefix            = local.service_common.azure_name_prefix
  environment                  = local.service_common.environment
  log_level                    = local.service_common.log_level
  resource_group_name          = local.service_common.resource_group_name
  location                     = local.service_common.location
  tags                         = local.service_common.tags
  container_app_environment_id = local.service_common.container_app_environment_id
  registry_id                  = local.service_common.registry_id
  registry_login_server        = local.service_common.registry_login_server
  min_instances                = local.service_common.min_instances
  max_instances                = local.service_common.max_instances

  db_host     = local.service_common.db_host
  db_name     = local.service_common.db_name
  db_username = local.service_common.db_username
  db_password = local.service_common.db_password

  key_vault_url        = local.service_common.key_vault_url
  jwt_secret_id        = local.service_common.jwt_secret_id
  jwt_secret_scope     = local.service_common.jwt_secret_scope
  internal_token_id    = local.service_common.internal_token_id
  internal_token_scope = local.service_common.internal_token_scope
  tuya_secret_id       = local.service_common.tuya_secret_id
  tuya_secret_scope    = local.service_common.tuya_secret_scope
  tuya_secret_name     = local.service_common.tuya_secret_name
  tuya_device_ids      = local.service_common.tuya_device_ids

  servicebus_namespace_fqdn = local.service_common.servicebus_namespace_fqdn
  servicebus_queue_name     = local.service_common.servicebus_queue_name
  servicebus_queue_id       = local.service_common.servicebus_queue_id
  servicebus_dlq_name       = local.service_common.servicebus_dlq_name

  # tuya-bridge is the only service that reads the Tuya secret.
  grant_tuya_secret_access = true
  servicebus_role          = "none"

  # DEVICE_SERVICE_URL is patched in post-create — see
  # null_resource.patch_tuya_bridge_url below.
  ignore_env_changes = true
}

module "device_service" {
  source = "./service"

  service_name = "device-service"
  port         = var.services["device-service"].port
  cpu          = var.services["device-service"].cpu
  memory       = var.services["device-service"].memory
  image_url    = var.image_urls["device-service"]

  azure_name_prefix            = local.service_common.azure_name_prefix
  environment                  = local.service_common.environment
  log_level                    = local.service_common.log_level
  resource_group_name          = local.service_common.resource_group_name
  location                     = local.service_common.location
  tags                         = local.service_common.tags
  container_app_environment_id = local.service_common.container_app_environment_id
  registry_id                  = local.service_common.registry_id
  registry_login_server        = local.service_common.registry_login_server
  min_instances                = local.service_common.min_instances
  max_instances                = local.service_common.max_instances

  db_host     = local.service_common.db_host
  db_name     = local.service_common.db_name
  db_username = local.service_common.db_username
  db_password = local.service_common.db_password

  key_vault_url        = local.service_common.key_vault_url
  jwt_secret_id        = local.service_common.jwt_secret_id
  jwt_secret_scope     = local.service_common.jwt_secret_scope
  internal_token_id    = local.service_common.internal_token_id
  internal_token_scope = local.service_common.internal_token_scope
  tuya_secret_id       = local.service_common.tuya_secret_id
  tuya_secret_scope    = local.service_common.tuya_secret_scope
  tuya_secret_name     = local.service_common.tuya_secret_name
  tuya_device_ids      = local.service_common.tuya_device_ids

  servicebus_namespace_fqdn = local.service_common.servicebus_namespace_fqdn
  servicebus_queue_name     = local.service_common.servicebus_queue_name
  servicebus_queue_id       = local.service_common.servicebus_queue_id
  servicebus_dlq_name       = local.service_common.servicebus_dlq_name

  # device-service writes to Service Bus.
  servicebus_role = "sender"

  # device-service dispatches commands to tuya-bridge. The reverse is
  # patched in post-create.
  tuya_bridge_url = module.tuya_bridge.url
}

module "service" {
  source = "./service"

  for_each = {
    for k, v in var.services :
    k => v if !contains(["device-service", "tuya-bridge"], k)
  }

  service_name = each.key
  port         = each.value.port
  cpu          = each.value.cpu
  memory       = each.value.memory
  image_url    = var.image_urls[each.key]

  azure_name_prefix            = local.service_common.azure_name_prefix
  environment                  = local.service_common.environment
  log_level                    = local.service_common.log_level
  resource_group_name          = local.service_common.resource_group_name
  location                     = local.service_common.location
  tags                         = local.service_common.tags
  container_app_environment_id = local.service_common.container_app_environment_id
  registry_id                  = local.service_common.registry_id
  registry_login_server        = local.service_common.registry_login_server
  min_instances                = local.service_common.min_instances
  max_instances                = local.service_common.max_instances

  db_host     = local.service_common.db_host
  db_name     = local.service_common.db_name
  db_username = local.service_common.db_username
  db_password = local.service_common.db_password

  key_vault_url        = local.service_common.key_vault_url
  jwt_secret_id        = local.service_common.jwt_secret_id
  jwt_secret_scope     = local.service_common.jwt_secret_scope
  internal_token_id    = local.service_common.internal_token_id
  internal_token_scope = local.service_common.internal_token_scope
  tuya_secret_id       = local.service_common.tuya_secret_id
  tuya_secret_scope    = local.service_common.tuya_secret_scope
  tuya_secret_name     = local.service_common.tuya_secret_name
  tuya_device_ids      = local.service_common.tuya_device_ids

  servicebus_namespace_fqdn = local.service_common.servicebus_namespace_fqdn
  servicebus_queue_name     = local.service_common.servicebus_queue_name
  servicebus_queue_id       = local.service_common.servicebus_queue_id
  servicebus_dlq_name       = local.service_common.servicebus_dlq_name

  # analytics-service consumes Service Bus messages. automation + user
  # don't touch it.
  servicebus_role = each.key == "analytics-service" ? "receiver" : "none"

  # analytics-service queries device-service for live counts;
  # automation-service issues device commands as part of /chase. The
  # extra env on user-service is harmless — filtering it out would
  # mean splitting the for_each further; not worth the readability cost.
  device_service_url = module.device_service.url
}

# -----------------------------------------------------------------------------
# Post-create patch: DEVICE_SERVICE_URL on tuya-bridge
# -----------------------------------------------------------------------------
# Mirrors the GCP module's parent-level patch. tuya-bridge is created
# first (no cross-ref), device-service follows (consumes tuya_bridge.url),
# then this null_resource patches DEVICE_SERVICE_URL onto tuya-bridge.
#
# Triggers on the tuya-bridge revision name so the patch re-runs after
# any in-place update of tuya-bridge (image change, resource-limit
# change). replace_triggered_by can't cross module boundaries from
# parent scope; the revision name is the workaround.
resource "null_resource" "patch_tuya_bridge_url" {
  triggers = {
    tuya_bridge_revision = module.tuya_bridge.latest_revision_name
    device_service_url   = module.device_service.url
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      echo ">>> Patching DEVICE_SERVICE_URL on ${module.tuya_bridge.container_app_name}"
      az containerapp update \
        --name "${module.tuya_bridge.container_app_name}" \
        --resource-group "${var.resource_group_name}" \
        --set-env-vars "DEVICE_SERVICE_URL=${module.device_service.url}" \
        >/dev/null
    EOT
  }
}
