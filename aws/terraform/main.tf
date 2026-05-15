# =============================================================================
# Smart Home Hub Platform - Main Terraform Configuration
# =============================================================================
# Cloud Computing Class Project - Demonstrating Platform Engineering
#
# AWS Services Used:
# - ECS Fargate (Compute)
# - SQS (Messaging)
# - RDS PostgreSQL (Database)
# - API Gateway, ALB, VPC (Networking)
# - ECR (Storage)
# - Secrets Manager (Security)
# - CloudWatch (Monitoring)
#
# Device-shadow state lives in Postgres (devices.state JSONB); the
# tuya-bridge container handles all Tuya Cloud I/O. There is no IoT Core
# dependency — see docs/device-shadow-design.md.
# =============================================================================

terraform {
  required_version = ">= 1.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "SmartHomePlatform"
      Environment = var.environment
      ManagedBy   = "Terraform"
      Course      = "CloudComputing"
    }
  }
}

# =============================================================================
# Local Variables
# =============================================================================
locals {
  name_prefix = "smarthome-${var.environment}"

  common_tags = {
    Project     = "SmartHomePlatform"
    Environment = var.environment
    Team        = "CloudComputingClass"
  }

  # AWS-only per-service knobs merged on top of the shared services map
  # (which carries `port`, `health_path`, `owner` — see
  # ../../services.auto.tfvars). ECS uses CPU shares + MiB; the ALB
  # listener rule needs an explicit priority so adding/renaming a service
  # can't silently renumber existing rules. Gaps left for future inserts.
  aws_overrides = {
    device-service     = { cpu = 256, memory = 512, priority = 100 }
    automation-service = { cpu = 256, memory = 512, priority = 110 }
    user-service       = { cpu = 256, memory = 512, priority = 120 }
    analytics-service  = { cpu = 256, memory = 512, priority = 130 }
    tuya-bridge        = { cpu = 256, memory = 512, priority = 140 }
  }

  services = {
    for k, v in var.services : k => merge(v, local.aws_overrides[k])
  }
}

# =============================================================================
# Networking Module
# =============================================================================
module "networking" {
  source = "./modules/networking"

  name_prefix = local.name_prefix
  environment = var.environment
  vpc_cidr    = var.vpc_cidr
  common_tags = local.common_tags
}

# =============================================================================
# Database Module (RDS PostgreSQL)
# =============================================================================
module "database" {
  source = "./modules/database"

  name_prefix             = local.name_prefix
  environment             = var.environment
  vpc_id                  = module.networking.vpc_id
  private_subnet_ids      = module.networking.private_subnet_ids
  db_username             = var.db_username
  db_password             = var.db_password
  allowed_security_groups = [module.cluster.ecs_tasks_security_group_id]
  common_tags             = local.common_tags
}

# =============================================================================
# Shared application secrets
# =============================================================================
# JWT signing secret for user-service (shared across all instances) and
# internal service-to-service auth token. Both are stored in Secrets
# Manager and injected into containers via the ECS task definition's
# `secrets` block, not as plaintext environment variables — anyone with
# ecs:DescribeTaskDefinition would otherwise be able to read them.
#
# Both rotate on every `terraform apply` (random_password has no keepers);
# services pick up the new values on next deploy.

resource "random_password" "jwt_secret" {
  length  = 48
  special = false
}

resource "aws_secretsmanager_secret" "jwt_secret" {
  name                    = "${local.name_prefix}-jwt-secret"
  description             = "JWT signing secret for user-service"
  recovery_window_in_days = 0
  tags                    = local.common_tags
}

resource "aws_secretsmanager_secret_version" "jwt_secret" {
  secret_id     = aws_secretsmanager_secret.jwt_secret.id
  secret_string = random_password.jwt_secret.result
}

resource "random_password" "internal_token" {
  length  = 48
  special = false
}

resource "aws_secretsmanager_secret" "internal_token" {
  name                    = "${local.name_prefix}-internal-token"
  description             = "Shared secret for device-service <-> tuya-bridge auth"
  recovery_window_in_days = 0
  tags                    = local.common_tags
}

resource "aws_secretsmanager_secret_version" "internal_token" {
  secret_id     = aws_secretsmanager_secret.internal_token.id
  secret_string = random_password.internal_token.result
}

# =============================================================================
# Event queue (consumed by analytics-service; written by device-service)
# =============================================================================
resource "aws_sqs_queue" "device_events" {
  name                       = "${local.name_prefix}-device-events"
  message_retention_seconds  = 86400
  visibility_timeout_seconds = 30
  receive_wait_time_seconds  = 10

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-device-events"
  })
}

resource "aws_sqs_queue" "device_events_dlq" {
  name = "${local.name_prefix}-device-events-dlq"
  tags = local.common_tags
}

resource "aws_sqs_queue_redrive_policy" "device_events" {
  queue_url = aws_sqs_queue.device_events.id
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.device_events_dlq.arn
    maxReceiveCount     = 3
  })
}

# =============================================================================
# Tuya Cloud credentials (read by tuya-bridge)
# =============================================================================
resource "aws_secretsmanager_secret" "tuya_credentials" {
  name                    = "${local.name_prefix}-tuya-credentials"
  description             = "Tuya Cloud API credentials"
  recovery_window_in_days = 0

  tags = local.common_tags
}

resource "aws_secretsmanager_secret_version" "tuya_credentials" {
  secret_id = aws_secretsmanager_secret.tuya_credentials.id
  secret_string = jsonencode({
    client_id     = var.tuya_client_id
    client_secret = var.tuya_client_secret
    region        = var.tuya_region
  })
}

# =============================================================================
# ECS shared cluster (Fargate cluster + ALB + IAM + SGs)
# =============================================================================
module "cluster" {
  source = "./modules/ecs"

  name_prefix       = local.name_prefix
  environment       = var.environment
  vpc_id            = module.networking.vpc_id
  public_subnet_ids = module.networking.public_subnet_ids

  jwt_secret_arn     = aws_secretsmanager_secret.jwt_secret.arn
  internal_token_arn = aws_secretsmanager_secret.internal_token.arn
  tuya_secret_arn    = aws_secretsmanager_secret.tuya_credentials.arn

  common_tags = local.common_tags
}

# =============================================================================
# Per-service module — one instance per entry in the shared services map
# =============================================================================
# Each instance owns its ECR repo, image build/push, log group, ALB target
# group + listener rule, ECS task def (rendered via templatefile), and
# ECS service. The shared cluster bits live in module.cluster above.
module "service" {
  source = "./modules/service"

  for_each = local.services

  service_name  = each.key
  port          = each.value.port
  health_path   = each.value.health_path
  cpu           = each.value.cpu
  memory        = each.value.memory
  priority      = each.value.priority
  desired_count = var.desired_count

  name_prefix = local.name_prefix
  environment = var.environment
  log_level   = var.log_level
  common_tags = local.common_tags

  cluster_id                  = module.cluster.cluster_id
  alb_listener_arn            = module.cluster.alb_listener_arn
  alb_dns_name                = module.cluster.alb_dns_name
  vpc_id                      = module.networking.vpc_id
  private_subnet_ids          = module.networking.private_subnet_ids
  ecs_tasks_security_group_id = module.cluster.ecs_tasks_security_group_id
  execution_role_arn          = module.cluster.execution_role_arn
  # tuya-bridge is the only service that reads the Tuya secret. Keying off
  # the literal service name keeps the special case visible in main.tf
  # rather than buried in the module.
  task_role_arn = each.key == "tuya-bridge" ? module.cluster.task_role_tuya_bridge_arn : module.cluster.task_role_arn
  aws_region    = module.cluster.aws_region

  db_endpoint = module.database.db_endpoint
  db_name     = module.database.db_name
  db_username = var.db_username
  db_password = var.db_password

  device_events_queue = aws_sqs_queue.device_events.url
  jwt_secret_arn      = aws_secretsmanager_secret.jwt_secret.arn
  internal_token_arn  = aws_secretsmanager_secret.internal_token.arn
  tuya_secret_name    = aws_secretsmanager_secret.tuya_credentials.name
  tuya_device_ids     = var.tuya_device_ids
}

# =============================================================================
# API Gateway Module
# =============================================================================
module "api_gateway" {
  source = "./modules/api-gateway"

  name_prefix  = local.name_prefix
  environment  = var.environment
  alb_dns_name = module.cluster.alb_dns_name
  services     = local.services
  common_tags  = local.common_tags
}

# =============================================================================
# Outputs
# =============================================================================
output "api_gateway_url" {
  description = "API Gateway URL (main entry point)"
  value       = module.api_gateway.api_url
}

output "alb_dns_name" {
  description = "Application Load Balancer DNS"
  value       = module.cluster.alb_dns_name
}

output "device_events_queue" {
  description = "SQS queue for device events"
  value       = aws_sqs_queue.device_events.url
}

output "service_urls" {
  description = "URLs for each microservice. Composed from each per-service module instance's `url` output."
  value       = { for k, mod in module.service : k => mod.url }
}
