output "service_urls" {
  description = "Map of service name -> public Container Apps ingress URL. Composed from the three sub-module call sites."
  value = merge(
    { "tuya-bridge" = module.tuya_bridge.url },
    { "device-service" = module.device_service.url },
    { for k, mod in module.service : k => mod.url },
  )
}

output "managed_identity_principal_ids" {
  description = "Map of service name -> runtime managed identity principal ID."
  value = merge(
    { "tuya-bridge" = module.tuya_bridge.principal_id },
    { "device-service" = module.device_service.principal_id },
    { for k, mod in module.service : k => mod.principal_id },
  )
}
