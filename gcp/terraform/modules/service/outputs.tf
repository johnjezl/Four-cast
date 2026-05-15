output "url" {
  description = "Public *.run.app URL for this service."
  value       = local.service.uri
}

output "service_account_email" {
  description = "Runtime SA email. Used by the parent for per-service Pub/Sub and Tuya IAM bindings."
  value       = google_service_account.this.email
}

output "service_name" {
  value = var.service_name
}

output "latest_created_revision" {
  description = "Name of the most recently created revision. Changes on every in-place update of the service — useful as a trigger for downstream null_resources that need to re-run whenever a new revision lands (e.g., re-patching DEVICE_SERVICE_URL onto tuya-bridge)."
  value       = local.service.latest_created_revision
}
