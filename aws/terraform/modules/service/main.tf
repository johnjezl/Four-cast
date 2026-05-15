# =============================================================================
# AWS per-service module
# =============================================================================
# One instance per entry in the shared services map. Owns everything that
# scales 1:1 with the service catalog:
#
#   - ECR repository (+ build/push provisioner triggered by source hash)
#   - CloudWatch log group
#   - ALB target group + listener rule (path-pattern keyed on the name)
#   - ECS task definition  ← rendered via templatefile() from
#                            templates/container_definition.json.tftpl
#   - ECS service
#
# The cluster, ALB, listener, security groups, and IAM roles are shared
# across all services and stay in the parent ecs module.
#
# Why the templatefile() for the container definition is the headline
# templating demo for this refactor:
#
#   1. ECS container definitions are gnarly JSON. The previous
#      jsonencode([{...}]) blob mixed Terraform expressions with JSON
#      structure inline — readable enough when there's one service, hard
#      to skim once it grows. The .tftpl is plain JSON with `${name}`,
#      `${image}`, `${jsonencode(...)}` substitutions.
#   2. Per-service values (name, image, port, environment, secrets) get
#      substituted once from a single template.
#   3. The rendered output is visible in `terraform plan` diffs, so
#      reviewers can read the actual container def that ECS will see.
# =============================================================================

# -----------------------------------------------------------------------------
# ECR repository for this service's image
# -----------------------------------------------------------------------------
resource "aws_ecr_repository" "this" {
  name                 = "${var.name_prefix}-${var.service_name}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.common_tags
}

# -----------------------------------------------------------------------------
# Build and push the container image on apply
# -----------------------------------------------------------------------------
# Rebuilds only when the per-service source OR shared/ changes — edits to
# the cloud abstraction layer must rebuild every image.
resource "null_resource" "build_and_push" {
  triggers = {
    repo_url = aws_ecr_repository.this.repository_url
    src_hash = sha256(join("|", concat(
      [for f in fileset("${path.root}/../services/${var.service_name}", "app/**/*.py") :
      "${f}=${filesha256("${path.root}/../services/${var.service_name}/${f}")}"],
      [for f in fileset("${path.root}/../services/${var.service_name}", "Dockerfile") :
      "${f}=${filesha256("${path.root}/../services/${var.service_name}/${f}")}"],
      [for f in fileset("${path.root}/../services/${var.service_name}", "requirements.txt") :
      "${f}=${filesha256("${path.root}/../services/${var.service_name}/${f}")}"],
      [for f in fileset("${path.root}/../../shared", "**/*.py") :
      "shared/${f}=${filesha256("${path.root}/../../shared/${f}")}"],
    )))
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      REPO_URL="${aws_ecr_repository.this.repository_url}"
      REGISTRY="$${REPO_URL%%/*}"
      REPO_ROOT="${path.root}/../.."
      DOCKERFILE="aws/services/${var.service_name}/Dockerfile"

      echo ">>> Building and pushing $${REPO_URL}:latest"
      aws ecr get-login-password --region "${var.aws_region}" | \
        docker login --username AWS --password-stdin "$REGISTRY" >/dev/null
      docker build -t "$${REPO_URL}:latest" -f "$REPO_ROOT/$DOCKERFILE" "$REPO_ROOT"
      docker push "$${REPO_URL}:latest"
    EOT
  }
}

# -----------------------------------------------------------------------------
# Log group
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.name_prefix}-${var.service_name}"
  retention_in_days = 7
  tags              = var.common_tags
}

# -----------------------------------------------------------------------------
# ALB target group + listener rule (path-pattern keyed on the service name)
# -----------------------------------------------------------------------------
resource "aws_lb_target_group" "this" {
  name                 = "${var.name_prefix}-${var.service_name}"
  port                 = var.port
  protocol             = "HTTP"
  vpc_id               = var.vpc_id
  target_type          = "ip"
  deregistration_delay = 30

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    path                = var.health_path
    matcher             = "200"
  }

  tags = var.common_tags
}

resource "aws_lb_listener_rule" "this" {
  listener_arn = var.alb_listener_arn
  priority     = var.priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }

  condition {
    path_pattern {
      # "user-service" -> /api/v1/user/*  ;  "tuya-bridge" stays as-is.
      values = [
        "/api/v1/${replace(var.service_name, "-service", "")}/*",
        "/api/v1/${replace(var.service_name, "-service", "")}",
      ]
    }
  }
}

# -----------------------------------------------------------------------------
# Container definition (rendered via templatefile)
# -----------------------------------------------------------------------------
# Cross-service URLs on AWS are all the same value: the shared ALB DNS
# name. Path-based routing on the LB handles the dispatch, so every
# service can carry the same TUYA_BRIDGE_URL / DEVICE_SERVICE_URL pointing
# at the ALB without a self-reference cycle (unlike GCP / Azure where
# each service has its own *.run.app / *.azurecontainerapps.io URL).
locals {
  alb_base_url = "http://${var.alb_dns_name}"

  environment_vars = [
    { name = "CLOUD_PROVIDER", value = "aws" },
    { name = "SERVICE_NAME", value = var.service_name },
    { name = "PORT", value = tostring(var.port) },
    { name = "DATABASE_URL", value = "postgresql+asyncpg://${var.db_username}:${var.db_password}@${var.db_endpoint}/${var.db_name}" },
    { name = "DEVICE_EVENTS_QUEUE", value = var.device_events_queue },
    { name = "ENVIRONMENT", value = var.environment },
    { name = "LOG_LEVEL", value = var.log_level },
    { name = "TUYA_BRIDGE_URL", value = local.alb_base_url },
    { name = "DEVICE_SERVICE_URL", value = local.alb_base_url },
    { name = "SECRET_NAME", value = var.tuya_secret_name },
    { name = "TUYA_DEVICE_IDS", value = var.tuya_device_ids },
  ]

  # Injected by the ECS agent from Secrets Manager at container start.
  # The execution role grants GetSecretValue on these ARNs (granted in
  # the cluster module).
  task_secrets = [
    { name = "JWT_SECRET", valueFrom = var.jwt_secret_arn },
    { name = "INTERNAL_TOKEN", valueFrom = var.internal_token_arn },
  ]
}

resource "aws_ecs_task_definition" "this" {
  family                   = "${var.name_prefix}-${var.service_name}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  depends_on = [null_resource.build_and_push]

  # templatefile() vs jsonencode(): the template is plain JSON with
  # named substitutions, which scans cleaner than mixed HCL+JSON. The
  # nested lists go through jsonencode() at the call site so commas /
  # quoting are unambiguous inside the template.
  container_definitions = templatefile("${path.module}/templates/container_definition.json.tftpl", {
    name             = var.service_name
    image            = "${aws_ecr_repository.this.repository_url}:latest"
    port             = var.port
    environment_json = jsonencode(local.environment_vars)
    secrets_json     = jsonencode(local.task_secrets)
    log_group        = aws_cloudwatch_log_group.this.name
    aws_region       = var.aws_region
  })

  tags = var.common_tags
}

# -----------------------------------------------------------------------------
# ECS service
# -----------------------------------------------------------------------------
resource "aws_ecs_service" "this" {
  name            = var.service_name
  cluster         = var.cluster_id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    security_groups = [var.ecs_tasks_security_group_id]
    subnets         = var.private_subnet_ids
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = var.service_name
    container_port   = var.port
  }

  # The listener rule must exist before the service tries to register
  # targets — the parent depends on the listener itself, the rule lives
  # in this module.
  depends_on = [aws_lb_listener_rule.this]

  tags = var.common_tags
}
