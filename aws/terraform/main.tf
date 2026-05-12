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

  # ALB listener-rule priorities are explicit so adding/renaming a service
  # can't silently renumber existing rules. Leave gaps between values for
  # future insertions.
  services = {
    device-service = {
      port        = 8001
      cpu         = 256
      memory      = 512
      health_path = "/health"
      owner       = "Member1"
      priority    = 100
    }
    automation-service = {
      port        = 8002
      cpu         = 256
      memory      = 512
      health_path = "/health"
      owner       = "Member2"
      priority    = 110
    }
    user-service = {
      port        = 8003
      cpu         = 256
      memory      = 512
      health_path = "/health"
      owner       = "Member3"
      priority    = 120
    }
    analytics-service = {
      port        = 8004
      cpu         = 256
      memory      = 512
      health_path = "/health"
      owner       = "Member4"
      priority    = 130
    }
    tuya-bridge = {
      port        = 8005
      cpu         = 256
      memory      = 512
      health_path = "/health"
      owner       = "Platform"
      priority    = 140
    }
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
  allowed_security_groups = [module.ecs.ecs_tasks_security_group_id]
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
# ECS Cluster Module (Fargate)
# =============================================================================
module "ecs" {
  source = "./modules/ecs"

  name_prefix        = local.name_prefix
  environment        = var.environment
  vpc_id             = module.networking.vpc_id
  private_subnet_ids = module.networking.private_subnet_ids
  public_subnet_ids  = module.networking.public_subnet_ids
  services           = local.services
  db_endpoint        = module.database.db_endpoint
  db_name            = module.database.db_name
  db_username        = var.db_username
  db_password        = var.db_password
  jwt_secret_arn     = aws_secretsmanager_secret.jwt_secret.arn
  internal_token_arn = aws_secretsmanager_secret.internal_token.arn
  desired_count      = var.desired_count
  log_level          = var.log_level

  device_events_queue = aws_sqs_queue.device_events.url
  tuya_secret_name    = aws_secretsmanager_secret.tuya_credentials.name
  tuya_secret_arn     = aws_secretsmanager_secret.tuya_credentials.arn
  tuya_device_ids     = var.tuya_device_ids

  common_tags = local.common_tags
}

# =============================================================================
# API Gateway Module
# =============================================================================
module "api_gateway" {
  source = "./modules/api-gateway"

  name_prefix  = local.name_prefix
  environment  = var.environment
  alb_dns_name = module.ecs.alb_dns_name
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
  value       = module.ecs.alb_dns_name
}

output "device_events_queue" {
  description = "SQS queue for device events"
  value       = aws_sqs_queue.device_events.url
}

output "service_urls" {
  description = "URLs for each microservice"
  value       = module.ecs.service_urls
}
