# =============================================================================
# Azure Container Registry + build-and-push
# =============================================================================
# One ACR instance holds all service images, addressed as
# <registry>.azurecr.io/<service>:latest. Rebuilds only when service
# source or shared/ changes.
#
# Requires `docker` and `az` on the machine running `terraform apply`.
# =============================================================================

locals {
  registry_name = substr("${replace(var.name_prefix, "-", "")}${var.unique_suffix}", 0, 50)
}

resource "azurerm_container_registry" "main" {
  name                = local.registry_name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Basic"
  admin_enabled       = false
  tags                = var.tags
}

locals {
  image_urls = {
    for k, _ in var.services :
    k => "${azurerm_container_registry.main.login_server}/${k}:latest"
  }
}

resource "null_resource" "build_and_push" {
  for_each = var.services

  triggers = {
    image_url = local.image_urls[each.key]
    # Trigger covers the per-service source AND shared/ - edits to the
    # cloud abstraction layer must rebuild every image.
    src_hash = sha256(join("|", concat(
      [for f in fileset("${path.root}/../services/${each.key}", "app/**/*.py") :
      "${f}=${filesha256("${path.root}/../services/${each.key}/${f}")}"],
      [for f in fileset("${path.root}/../services/${each.key}", "Dockerfile") :
      "${f}=${filesha256("${path.root}/../services/${each.key}/${f}")}"],
      [for f in fileset("${path.root}/../services/${each.key}", "requirements.txt") :
      "${f}=${filesha256("${path.root}/../services/${each.key}/${f}")}"],
      [for f in fileset("${path.root}/../../shared", "**/*.py") :
      "shared/${f}=${filesha256("${path.root}/../../shared/${f}")}"],
    )))
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      IMAGE_URL="${local.image_urls[each.key]}"
      REPO_ROOT="${path.root}/../.."
      DOCKERFILE="azure/services/${each.key}/Dockerfile"

      echo ">>> Building and pushing $${IMAGE_URL}"
      az acr login --name "${azurerm_container_registry.main.name}" >/dev/null
      docker build -t "$IMAGE_URL" -f "$REPO_ROOT/$DOCKERFILE" "$REPO_ROOT"
      docker push "$IMAGE_URL"
    EOT
  }

  depends_on = [azurerm_container_registry.main]
}
