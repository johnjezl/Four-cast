output "service_urls" {
  description = "Map of service name -> public Container Apps ingress URL."
  value = merge(
    { for k, v in azurerm_container_app.main : k => "https://${v.ingress[0].fqdn}" },
    {
      "device-service" = "https://${azurerm_container_app.device_service.ingress[0].fqdn}"
      "tuya-bridge"    = "https://${azurerm_container_app.tuya_bridge.ingress[0].fqdn}"
    },
  )
}

output "managed_identity_principal_ids" {
  description = "Map of service name -> runtime managed identity principal ID."
  value       = { for k, v in azurerm_user_assigned_identity.services : k => v.principal_id }
}
