output "url" {
  description = "Public Container Apps ingress URL (https://...azurecontainerapps.io)."
  value       = "https://${local.container_app.ingress[0].fqdn}"
}

output "principal_id" {
  description = "Managed identity principal ID. Surfaced so the parent can compose maps for backwards compatibility on container-apps module outputs."
  value       = azurerm_user_assigned_identity.this.principal_id
}

output "container_app_name" {
  description = "Container App resource name. Used by the parent's null_resource.patch_tuya_bridge_url to address the right app via az containerapp update."
  value       = local.container_app.name
}

output "latest_revision_name" {
  description = "Most recently created revision. Changes on every in-place update — useful as a trigger for downstream null_resources (e.g., the DEVICE_SERVICE_URL patch on tuya-bridge)."
  value       = local.container_app.latest_revision_name
}
