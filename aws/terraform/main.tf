# =============================================================================
# Smart Home Hub Platform - Main Terraform Configuration
# =============================================================================
# Cloud Computing Class Project - Demonstrating Platform Engineering
# 
# AWS Services Used (12):
# - ECS Fargate, Lambda (Compute)
# - SQS, EventBridge (Messaging)
# - RDS PostgreSQL, Timestream (Database)
# - IoT Core (IoT)
# - API Gateway, ALB, VPC (Networking)
# - ECR (Storage)
# - Secrets Manager (Security)
# - CloudWatch (Monitoring)
# =============================================================================

terraform {
  required_version = ">= 1.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
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

  services = {
    device-service = {
      port        = 8001
      cpu         = 256
      memory      = 512
      health_path = "/health"
      owner       = "Member1"
    }
    automation-service = {
      port        = 8002
      cpu         = 256
      memory      = 512
      health_path = "/health"
      owner       = "Member2"
    }
    user-service = {
      port        = 8003
      cpu         = 256
      memory      = 512
      health_path = "/health"
      owner       = "Member3"
    }
    analytics-service = {
      port        = 8004
      cpu         = 256
      memory      = 512
      health_path = "/health"
      owner       = "Member4"
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
# JWT signing secret for user-service (shared across all instances)
# =============================================================================
resource "random_password" "jwt_secret" {
  length  = 48
  special = false
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
  jwt_secret         = random_password.jwt_secret.result
  desired_count      = var.desired_count

  # IoT Core integration
  iot_endpoint        = module.iot.iot_endpoint
  device_events_queue = module.iot.device_events_queue_url

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
# IoT Core Module (NEW - for device connectivity)
# =============================================================================
module "iot" {
  source = "./modules/iot"

  name_prefix        = local.name_prefix
  environment        = var.environment
  tuya_device_ids    = var.tuya_device_ids
  tuya_client_id     = var.tuya_client_id
  tuya_client_secret = var.tuya_client_secret
  tuya_region        = var.tuya_region
  enable_timestream  = var.enable_timestream
  common_tags        = local.common_tags
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

output "iot_endpoint" {
  description = "AWS IoT Core endpoint for device connections"
  value       = module.iot.iot_endpoint
}

output "device_events_queue" {
  description = "SQS queue for device events"
  value       = module.iot.device_events_queue_url
}

output "timestream_database" {
  description = "Timestream database for device metrics (null if disabled)"
  value       = module.iot.timestream_database
}

output "service_urls" {
  description = "URLs for each microservice"
  value       = module.ecs.service_urls
}
