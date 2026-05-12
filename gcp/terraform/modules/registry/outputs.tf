output "image_urls" {
  description = "Map of service name -> fully qualified image URL (tagged :latest). Depends on the build-and-push provisioner so Cloud Run only starts after the push completes."
  value       = local.image_urls

  # Force the consumer (Cloud Run module) to wait for builds to finish.
  depends_on = [null_resource.build_and_push]
}

output "repository_id" {
  value = google_artifact_registry_repository.main.repository_id
}
