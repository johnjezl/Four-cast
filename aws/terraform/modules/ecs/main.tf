# =============================================================================
# ECS Fargate Module
# =============================================================================
# Runs containerized microservices on AWS Fargate.
# Textbook Reference: Ch. 3 - Platform abstraction via containers
# =============================================================================

# -----------------------------------------------------------------------------
# ECS Cluster
# -----------------------------------------------------------------------------
resource "aws_ecs_cluster" "main" {
  name = "${var.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = var.common_tags
}

# -----------------------------------------------------------------------------
# ECR Repositories
# -----------------------------------------------------------------------------
resource "aws_ecr_repository" "services" {
  for_each = var.services

  name                 = "${var.name_prefix}-${each.key}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.common_tags
}

# -----------------------------------------------------------------------------
# Build and push container images on apply
# -----------------------------------------------------------------------------
# Rebuilds only when the relevant service source files actually change.
# Requires `docker` and `aws` CLI to be available on the machine running
# `terraform apply`, and the current user to be in the `docker` group.
resource "null_resource" "build_and_push" {
  for_each = var.services

  triggers = {
    repo_url = aws_ecr_repository.services[each.key].repository_url
    # Trigger covers the per-service source AND shared/ — edits to the
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
      REPO_URL="${aws_ecr_repository.services[each.key].repository_url}"
      REGISTRY="$${REPO_URL%%/*}"
      REPO_ROOT="${path.root}/../.."
      DOCKERFILE="aws/services/${each.key}/Dockerfile"
      REGION="${data.aws_region.current.name}"

      echo ">>> Building and pushing $${REPO_URL}:latest"
      aws ecr get-login-password --region "$REGION" | \
        docker login --username AWS --password-stdin "$REGISTRY" >/dev/null
      docker build -t "$${REPO_URL}:latest" -f "$REPO_ROOT/$DOCKERFILE" "$REPO_ROOT"
      docker push "$${REPO_URL}:latest"
    EOT
  }
}

# -----------------------------------------------------------------------------
# Application Load Balancer
# -----------------------------------------------------------------------------
resource "aws_lb" "main" {
  name               = "${var.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  # AWS default is 60s. The automation-service /chase endpoint holds the
  # request open while it animates frames; with the in-app cap of 270s
  # and 30s of HTTP-RTT cushion, the LB ceiling needs to be ≥300s or
  # the ALB resets long-running requests before the handler returns.
  # Matches Cloud Run's default 300s request timeout so the chase math
  # is identical across clouds.
  idle_timeout = 300

  tags = var.common_tags
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      message_body = "{\"status\": \"healthy\", \"platform\": \"SmartHome Hub\"}"
      status_code  = "200"
    }
  }
}

# -----------------------------------------------------------------------------
# Target Groups & Listener Rules
# -----------------------------------------------------------------------------
resource "aws_lb_target_group" "services" {
  for_each = var.services

  name                 = "${var.name_prefix}-${each.key}"
  port                 = each.value.port
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
    path                = each.value.health_path
    matcher             = "200"
  }

  tags = var.common_tags
}

resource "aws_lb_listener_rule" "services" {
  for_each = var.services

  listener_arn = aws_lb_listener.http.arn
  priority     = each.value.priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.services[each.key].arn
  }

  condition {
    path_pattern {
      values = ["/api/v1/${replace(each.key, "-service", "")}/*", "/api/v1/${replace(each.key, "-service", "")}"]
    }
  }
}

# -----------------------------------------------------------------------------
# Security Groups
# -----------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb-sg"
  description = "Security group for ALB"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.common_tags
}

resource "aws_security_group" "ecs_tasks" {
  name        = "${var.name_prefix}-ecs-tasks-sg"
  description = "Security group for ECS tasks"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 0
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.common_tags
}

# -----------------------------------------------------------------------------
# ECS Task Definitions
# -----------------------------------------------------------------------------
resource "aws_ecs_task_definition" "services" {
  for_each = var.services

  family                   = "${var.name_prefix}-${each.key}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = each.value.cpu
  memory                   = each.value.memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  # Coupling: the literal "tuya-bridge" must match the key used in
  # local.services. Rename either side and the bridge silently loses
  # secretsmanager:GetSecretValue on the Tuya secret. Worth promoting to
  # a per-service `task_role` field if more services need scoped roles.
  task_role_arn = each.key == "tuya-bridge" ? aws_iam_role.ecs_task_tuya_bridge.arn : aws_iam_role.ecs_task.arn

  depends_on = [null_resource.build_and_push]

  container_definitions = jsonencode([
    {
      name      = each.key
      image     = "${aws_ecr_repository.services[each.key].repository_url}:latest"
      essential = true

      portMappings = [
        {
          containerPort = each.value.port
          hostPort      = each.value.port
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "CLOUD_PROVIDER", value = "aws" },
        { name = "SERVICE_NAME", value = each.key },
        { name = "PORT", value = tostring(each.value.port) },
        { name = "DATABASE_URL", value = "postgresql+asyncpg://${var.db_username}:${var.db_password}@${var.db_endpoint}/${var.db_name}" },
        { name = "DEVICE_EVENTS_QUEUE", value = var.device_events_queue },
        { name = "ENVIRONMENT", value = var.environment },
        { name = "LOG_LEVEL", value = var.log_level },
        { name = "TUYA_BRIDGE_URL", value = "http://${aws_lb.main.dns_name}" },
        { name = "DEVICE_SERVICE_URL", value = "http://${aws_lb.main.dns_name}" },
        { name = "SECRET_NAME", value = var.tuya_secret_name },
        { name = "TUYA_DEVICE_IDS", value = var.tuya_device_ids }
      ]

      # Pulled from Secrets Manager at container start and injected as env
      # vars. The execution role (not the task role) needs GetSecretValue
      # on these ARNs.
      secrets = [
        { name = "JWT_SECRET", valueFrom = var.jwt_secret_arn },
        { name = "INTERNAL_TOKEN", valueFrom = var.internal_token_arn }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/${var.name_prefix}-${each.key}"
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

  tags = var.common_tags
}

# -----------------------------------------------------------------------------
# ECS Services
# -----------------------------------------------------------------------------
resource "aws_ecs_service" "services" {
  for_each = var.services

  name            = each.key
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.services[each.key].arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    security_groups = [aws_security_group.ecs_tasks.id]
    subnets         = var.private_subnet_ids
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.services[each.key].arn
    container_name   = each.key
    container_port   = each.value.port
  }

  depends_on = [aws_lb_listener.http]

  tags = var.common_tags
}

# -----------------------------------------------------------------------------
# CloudWatch Log Groups
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "services" {
  for_each = var.services

  name              = "/ecs/${var.name_prefix}-${each.key}"
  retention_in_days = 7

  tags = var.common_tags
}

# -----------------------------------------------------------------------------
# IAM Roles
# -----------------------------------------------------------------------------
resource "aws_iam_role" "ecs_execution" {
  name = "${var.name_prefix}-ecs-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Lets the ECS agent pull JWT_SECRET and INTERNAL_TOKEN from Secrets
# Manager when starting containers (referenced by the task definition's
# `secrets` block).
resource "aws_iam_role_policy" "ecs_execution_secrets" {
  name = "${var.name_prefix}-ecs-execution-secrets"
  role = aws_iam_role.ecs_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [var.jwt_secret_arn, var.internal_token_arn]
    }]
  })
}

resource "aws_iam_role" "ecs_task" {
  name = "${var.name_prefix}-ecs-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy" "ecs_task" {
  name = "${var.name_prefix}-ecs-task-policy"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = ["*"]
      }
    ]
  })
}

# Specialized task role for tuya-bridge: adds read access to the Tuya
# Cloud credentials secret. No other service needs this, so we don't grant
# it on the generic role.
resource "aws_iam_role" "ecs_task_tuya_bridge" {
  name = "${var.name_prefix}-ecs-task-tuya-bridge"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy" "ecs_task_tuya_bridge" {
  name = "${var.name_prefix}-ecs-task-tuya-bridge-policy"
  role = aws_iam_role.ecs_task_tuya_bridge.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [var.tuya_secret_arn]
    }]
  })
}

# -----------------------------------------------------------------------------
# Data Sources
# -----------------------------------------------------------------------------
data "aws_region" "current" {}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "cluster_id" {
  value = aws_ecs_cluster.main.id
}

output "alb_dns_name" {
  value = aws_lb.main.dns_name
}

output "ecs_tasks_security_group_id" {
  value = aws_security_group.ecs_tasks.id
}

output "service_urls" {
  value = { for k, v in var.services : k => "http://${aws_lb.main.dns_name}/api/v1/${replace(k, "-service", "")}" }
}

output "ecr_repository_urls" {
  value = { for k, v in aws_ecr_repository.services : k => v.repository_url }
}
