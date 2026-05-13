output "image_urls" {
  description = "Map of service name -> fully qualified image URL (tagged :latest). Depends on the build-and-push provisioner so Container Apps only start after the push completes."
  value       = local.image_urls

  depends_on = [null_resource.build_and_push]
}

output "registry_id" {
  value = azurerm_container_registry.main.id
}

output "registry_name" {
  value = azurerm_container_registry.main.name
}

output "login_server" {
  value = azurerm_container_registry.main.login_server
}
