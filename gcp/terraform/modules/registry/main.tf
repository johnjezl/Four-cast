# =============================================================================
# Artifact Registry + build-and-push
# =============================================================================
# One Artifact Registry repo holds all service images, addressed as
# <region>-docker.pkg.dev/<project>/<repo>/<service>:latest. Rebuilds
# only when service source actually changes — same trigger pattern as
# the AWS ECR module.
#
# Requires `docker` and `gcloud` on the machine running `terraform
# apply`. `gcloud auth configure-docker` is invoked per build so the
# Docker daemon can push to *.pkg.dev.
# =============================================================================

resource "google_artifact_registry_repository" "main" {
  location      = var.region
  repository_id = "${var.name_prefix}-services"
  description   = "Container images for SmartHome services"
  format        = "DOCKER"
}

locals {
  registry_host = "${var.region}-docker.pkg.dev"
  image_urls = {
    for k, _ in var.services :
    k => "${local.registry_host}/${var.project_id}/${google_artifact_registry_repository.main.repository_id}/${k}:latest"
  }
}

resource "null_resource" "build_and_push" {
  for_each = var.services

  triggers = {
    image_url = local.image_urls[each.key]
    src_hash = sha256(join("|", concat(
      [for f in fileset("${path.root}/../services/${each.key}", "app/**/*.py") :
      "${f}=${filesha256("${path.root}/../services/${each.key}/${f}")}"],
      [for f in fileset("${path.root}/../services/${each.key}", "Dockerfile") :
      "${f}=${filesha256("${path.root}/../services/${each.key}/${f}")}"],
      [for f in fileset("${path.root}/../services/${each.key}", "requirements.txt") :
      "${f}=${filesha256("${path.root}/../services/${each.key}/${f}")}"],
    )))
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      IMAGE_URL="${local.image_urls[each.key]}"
      REGISTRY="${local.registry_host}"
      SERVICE_DIR="${path.root}/../services/${each.key}"

      echo ">>> Building and pushing $${IMAGE_URL}"
      gcloud auth configure-docker "$REGISTRY" --quiet >/dev/null
      docker build -t "$IMAGE_URL" "$SERVICE_DIR"
      docker push "$IMAGE_URL"
    EOT
  }

  depends_on = [google_artifact_registry_repository.main]
}
