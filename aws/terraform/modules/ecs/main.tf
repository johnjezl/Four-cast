# =============================================================================
# ECS shared cluster module
# =============================================================================
# Owns everything that is one-per-deployment rather than one-per-service:
#
#   - ECS cluster
#   - ALB (+ HTTP listener with fixed-response default)
#   - Security groups (alb, ecs_tasks)
#   - IAM roles (execution role, generic task role, scoped tuya-bridge
#     task role)
#   - Region data source (re-exported so the per-service module doesn't
#     need its own provider data lookup)
#
# Per-service resources (ECR repo, task def, service, target group,
# listener rule, log group, build/push provisioner) live in
# `aws/terraform/modules/service/`, instantiated once per entry in
# `var.services` from the parent main.tf. This split mirrors the GCP /
# Azure module shape and is where templatefile() does the heavy lifting
# for container definitions.
# =============================================================================

# -----------------------------------------------------------------------------
# ECS cluster
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
# Security groups
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
# IAM roles
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
# Manager when starting containers (referenced by every task definition's
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
# Cloud credentials secret. No other service needs this, so we don't
# grant it on the generic role.
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
# Data sources
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

output "alb_listener_arn" {
  value = aws_lb_listener.http.arn
}

output "ecs_tasks_security_group_id" {
  value = aws_security_group.ecs_tasks.id
}

output "execution_role_arn" {
  value = aws_iam_role.ecs_execution.arn
}

output "task_role_arn" {
  value = aws_iam_role.ecs_task.arn
}

output "task_role_tuya_bridge_arn" {
  value = aws_iam_role.ecs_task_tuya_bridge.arn
}

output "aws_region" {
  value = data.aws_region.current.name
}
