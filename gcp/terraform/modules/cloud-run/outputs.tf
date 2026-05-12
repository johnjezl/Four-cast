output "service_urls" {
  description = "Map of service name -> public *.run.app URL. Each service is independently reachable; there is no shared LB."
  value       = { for k, v in google_cloud_run_v2_service.main : k => v.uri }
}

output "service_account_emails" {
  description = "Map of service name -> runtime service account email. Use these for per-service IAM grants (e.g., Tuya secret access)."
  value       = { for k, v in google_service_account.services : k => v.email }
}
