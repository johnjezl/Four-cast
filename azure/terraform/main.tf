# =============================================================================
# Smart Home Hub Platform - Azure Main Terraform Configuration
# =============================================================================
# Azure services used:
# - Container Apps (Compute, per-service *.azurecontainerapps.io URLs)
# - Azure Database for PostgreSQL Flexible Server
# - Azure Container Registry
# - Service Bus queue + dead-letter queue forwarding
# - Key Vault secrets read through per-service managed identities
#
# Service containers run identical code on AWS, GCP, and Azure. The
# shared/cloud adapter is selected at runtime with CLOUD_PROVIDER.
# =============================================================================

terraform {
  required_version = ">= 1.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

provider "azurerm" {
  features {}

  subscription_id = var.azure_subscription_id

  # Let the azurerm provider itself handle resource provider registration.
  # It registers idempotently (skips already-registered providers) and
  # holds the dependency internally — every resource in the config waits
  # for its provider namespace before creation, so no `depends_on` chain
  # is needed.
  #
  # We use `"none"` for the preset (don't register anything we don't ask
  # for) and list our seven explicitly via `resource_providers_to_register`.
  # This is the alternative to the `azurerm_resource_provider_registration`
  # resource pattern, which works but creates a destroy-cycle UX problem:
  # `prevent_destroy` is needed to stop `terraform destroy` from
  # unregistering the providers subscription-wide, but then the explicit
  # `state rm` step makes every subsequent fresh-state apply error out
  # with "already exists - to be managed via Terraform this resource
  # needs to be imported into the State", requiring a manual import
  # dance. The provider's built-in registration sidesteps the whole loop.
  #
  # Upgrade note: if your state still has `azurerm_resource_provider_registration`
  # entries from the previous design, run `terraform state rm` on each one
  # BEFORE applying this config — otherwise terraform plans them as destroys
  # (the resource block no longer exists and `prevent_destroy` is gone), which
  # would unregister them subscription-wide.
  resource_provider_registrations = "none"
  resource_providers_to_register = [
    "Microsoft.App",
    "Microsoft.ContainerRegistry",
    "Microsoft.DBforPostgreSQL",
    "Microsoft.KeyVault",
    "Microsoft.ManagedIdentity",
    "Microsoft.OperationalInsights",
    "Microsoft.ServiceBus",
  ]
}

data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 6
  lower   = true
  numeric = true
  special = false
  upper   = false
}

# =============================================================================
# Local Variables
# =============================================================================
locals {
  name_prefix = "smarthome-${var.environment}"
  short_env   = substr(var.environment, 0, 4)

  common_tags = {
    Project     = "SmartHomePlatform"
    Environment = var.environment
    Team        = "CloudComputingClass"
    ManagedBy   = "Terraform"
  }

  # Azure-only per-service knobs merged on top of the shared services map
  # (see ../../services.tf). Container Apps consumption resources use a
  # cpu float + memory string. 0.5 vCPU + 1Gi memory is the smallest
  # pair with enough headroom for FastAPI plus SQLAlchemy and cloud SDK
  # clients.
  azure_overrides = {
    device-service     = { cpu = 0.5, memory = "1Gi" }
    automation-service = { cpu = 0.5, memory = "1Gi" }
    user-service       = { cpu = 0.5, memory = "1Gi" }
    analytics-service  = { cpu = 0.5, memory = "1Gi" }
    tuya-bridge        = { cpu = 0.5, memory = "1Gi" }
  }

  services = {
    for k, v in var.services : k => merge(v, local.azure_overrides[k])
  }
}

# =============================================================================
# Resource Group
# =============================================================================
resource "azurerm_resource_group" "main" {
  name     = "rg-${local.name_prefix}"
  location = var.azure_location
  tags     = local.common_tags
}

# =============================================================================
# Shared application secrets (Key Vault-backed)
# =============================================================================
resource "azurerm_key_vault" "app" {
  name                       = "kvsh${local.short_env}${random_string.suffix.result}"
  location                   = azurerm_resource_group.main.location
  resource_group_name        = azurerm_resource_group.main.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = false
  soft_delete_retention_days = 7
  tags                       = local.common_tags
}

# The identity running Terraform needs data-plane rights before it can
# create Key Vault secrets when RBAC authorization is enabled.
resource "azurerm_role_assignment" "terraform_key_vault_secrets_officer" {
  scope                = azurerm_key_vault.app.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "random_password" "jwt_secret" {
  length  = 48
  special = false
}

resource "azurerm_key_vault_secret" "jwt_secret" {
  name         = "jwt-secret"
  value        = random_password.jwt_secret.result
  key_vault_id = azurerm_key_vault.app.id

  depends_on = [azurerm_role_assignment.terraform_key_vault_secrets_officer]
}

resource "random_password" "internal_token" {
  length  = 48
  special = false
}

resource "azurerm_key_vault_secret" "internal_token" {
  name         = "internal-token"
  value        = random_password.internal_token.result
  key_vault_id = azurerm_key_vault.app.id

  depends_on = [azurerm_role_assignment.terraform_key_vault_secrets_officer]
}

# =============================================================================
# Service Bus: device-events bus
# =============================================================================
# Azure Service Bus queues have a native dead-letter subqueue. We also
# provision an explicit queue and forward dead-lettered messages there
# so the AWS/GCP DLQ comparison remains concrete in Terraform outputs.
resource "azurerm_servicebus_namespace" "device_events" {
  name                = "sb-${local.name_prefix}-${random_string.suffix.result}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "Standard"
  tags                = local.common_tags
}

resource "azurerm_servicebus_queue" "device_events_dlq" {
  name         = "${local.name_prefix}-device-events-dlq"
  namespace_id = azurerm_servicebus_namespace.device_events.id
}

resource "azurerm_servicebus_queue" "device_events" {
  name                                 = "${local.name_prefix}-device-events"
  namespace_id                         = azurerm_servicebus_namespace.device_events.id
  lock_duration                        = "PT30S"
  default_message_ttl                  = "P1D"
  max_delivery_count                   = 5
  dead_lettering_on_message_expiration = true
  forward_dead_lettered_messages_to    = azurerm_servicebus_queue.device_events_dlq.name
}

# =============================================================================
# Key Vault: Tuya Cloud credentials
# =============================================================================
resource "azurerm_key_vault_secret" "tuya_credentials" {
  name         = "tuya-credentials"
  key_vault_id = azurerm_key_vault.app.id
  value = jsonencode({
    client_id     = var.tuya_client_id
    client_secret = var.tuya_client_secret
    region        = var.tuya_region
  })

  depends_on = [azurerm_role_assignment.terraform_key_vault_secrets_officer]
}

# =============================================================================
# Azure Container Registry - build and push images
# =============================================================================
module "registry" {
  source = "./modules/registry"

  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  name_prefix         = local.name_prefix
  unique_suffix       = random_string.suffix.result
  services            = local.services
  tags                = local.common_tags
}

# =============================================================================
# Azure Database for PostgreSQL Flexible Server
# =============================================================================
module "database" {
  source = "./modules/database"

  resource_group_name = azurerm_resource_group.main.name
  location            = coalesce(var.db_location, var.azure_location)
  name_prefix         = local.name_prefix
  unique_suffix       = random_string.suffix.result
  db_username         = var.db_username
  db_password         = var.db_password
  tags                = local.common_tags
}

# =============================================================================
# Container Apps services
# =============================================================================
module "container_apps" {
  source = "./modules/container-apps"

  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  name_prefix         = local.name_prefix
  environment         = var.environment
  tags                = local.common_tags

  services              = local.services
  image_urls            = module.registry.image_urls
  registry_id           = module.registry.registry_id
  registry_login_server = module.registry.login_server

  db_host     = module.database.fqdn
  db_name     = module.database.db_name
  db_username = var.db_username
  db_password = var.db_password

  key_vault_url = azurerm_key_vault.app.vault_uri

  jwt_secret_id    = azurerm_key_vault_secret.jwt_secret.versionless_id
  jwt_secret_scope = azurerm_key_vault_secret.jwt_secret.resource_versionless_id

  internal_token_id    = azurerm_key_vault_secret.internal_token.versionless_id
  internal_token_scope = azurerm_key_vault_secret.internal_token.resource_versionless_id

  tuya_secret_id    = azurerm_key_vault_secret.tuya_credentials.versionless_id
  tuya_secret_scope = azurerm_key_vault_secret.tuya_credentials.resource_versionless_id
  tuya_secret_name  = azurerm_key_vault_secret.tuya_credentials.name
  tuya_device_ids   = var.tuya_device_ids

  servicebus_namespace_fqdn = "${azurerm_servicebus_namespace.device_events.name}.servicebus.windows.net"
  servicebus_queue_name     = azurerm_servicebus_queue.device_events.name
  servicebus_queue_id       = azurerm_servicebus_queue.device_events.id
  servicebus_dlq_name       = azurerm_servicebus_queue.device_events_dlq.name

  min_instances = var.min_instances
  max_instances = var.max_instances
  log_level     = var.log_level
}

# =============================================================================
# Outputs
# =============================================================================
output "service_urls" {
  description = "Per-service public URLs (*.azurecontainerapps.io). There is no shared API Gateway in this deployment - each service is reached directly."
  value       = module.container_apps.service_urls
}

output "resource_group_name" {
  description = "Azure resource group containing the deployment."
  value       = azurerm_resource_group.main.name
}

output "container_registry_name" {
  description = "Azure Container Registry name used for service images."
  value       = module.registry.registry_name
}

output "container_registry_login_server" {
  description = "Azure Container Registry login server used for service images."
  value       = module.registry.login_server
}

output "key_vault_name" {
  description = "Key Vault name holding app and Tuya secrets."
  value       = azurerm_key_vault.app.name
}

output "db_host" {
  description = "Azure PostgreSQL Flexible Server hostname."
  value       = module.database.fqdn
}

output "servicebus_queue" {
  description = "Service Bus queue used for device events."
  value       = azurerm_servicebus_queue.device_events.name
}

output "servicebus_dlq" {
  description = "Explicit queue receiving forwarded dead-lettered device events."
  value       = azurerm_servicebus_queue.device_events_dlq.name
}
