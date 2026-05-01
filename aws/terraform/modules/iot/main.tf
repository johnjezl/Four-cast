# =============================================================================
# AWS IoT Core Module
# =============================================================================
# Textbook Reference: Ch. 3 - "Use managed services for non-differentiating work"
# 
# AWS IoT Core provides:
# - Device Shadows (cloud-side state for offline devices)
# - Rules Engine (route messages to other AWS services)
# - MQTT Broker (we use for internal pub/sub)
#
# Since Tuya devices can't connect directly to IoT Core, we use Lambda
# as a bridge to sync state between Tuya Cloud and IoT Core Shadows.
# =============================================================================

# -----------------------------------------------------------------------------
# Data Sources
# -----------------------------------------------------------------------------
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

data "aws_iot_endpoint" "current" {
  endpoint_type = "iot:Data-ATS"
}

# -----------------------------------------------------------------------------
# IoT Thing Type (Device Template)
# -----------------------------------------------------------------------------
resource "aws_iot_thing_type" "smart_bulb" {
  name = "${var.name_prefix}-smart-bulb"

  properties {
    description           = "Tuya-based smart bulb bridged via Lambda"
    searchable_attributes = ["manufacturer", "model", "room"]
  }

  tags = var.common_tags
}

# -----------------------------------------------------------------------------
# IoT Policy (Permissions for devices/services)
# -----------------------------------------------------------------------------
resource "aws_iot_policy" "device_policy" {
  name = "${var.name_prefix}-device-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "iot:Connect",
          "iot:Publish",
          "iot:Subscribe",
          "iot:Receive"
        ]
        Resource = ["*"]
      },
      {
        Effect = "Allow"
        Action = [
          "iot:GetThingShadow",
          "iot:UpdateThingShadow",
          "iot:DeleteThingShadow"
        ]
        Resource = ["*"]
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# SQS Queue for Device Events
# -----------------------------------------------------------------------------
# Textbook: Event-driven architecture for loose coupling between services

resource "aws_sqs_queue" "device_events" {
  name                       = "${var.name_prefix}-device-events"
  message_retention_seconds  = 86400  # 1 day
  visibility_timeout_seconds = 30
  receive_wait_time_seconds  = 10     # Long polling

  tags = merge(var.common_tags, {
    Name = "${var.name_prefix}-device-events"
  })
}

resource "aws_sqs_queue" "device_events_dlq" {
  name = "${var.name_prefix}-device-events-dlq"
  
  tags = var.common_tags
}

resource "aws_sqs_queue_redrive_policy" "device_events" {
  queue_url = aws_sqs_queue.device_events.id
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.device_events_dlq.arn
    maxReceiveCount     = 3
  })
}

# -----------------------------------------------------------------------------
# IoT Rule: Shadow Updates → SQS
# -----------------------------------------------------------------------------
# When device shadow is updated, send event to SQS for Automation Service

resource "aws_iot_topic_rule" "shadow_to_sqs" {
  name        = "${replace(var.name_prefix, "-", "_")}_shadow_updates"
  description = "Forward device shadow updates to SQS for processing"
  enabled     = true
  sql         = "SELECT *, topic(3) as deviceId FROM '$aws/things/+/shadow/update/accepted'"
  sql_version = "2016-03-23"

  sqs {
    queue_url  = aws_sqs_queue.device_events.url
    role_arn   = aws_iam_role.iot_sqs_role.arn
    use_base64 = false
  }

  tags = var.common_tags
}

# -----------------------------------------------------------------------------
# IoT Rule: Commands → Lambda → Tuya
# -----------------------------------------------------------------------------
# When desired state changes, trigger Lambda to send command to Tuya

resource "aws_iot_topic_rule" "command_to_tuya" {
  name        = "${replace(var.name_prefix, "-", "_")}_commands"
  description = "Forward commands to Lambda for Tuya delivery"
  enabled     = true
  sql         = "SELECT *, topic(3) as thingName FROM '$aws/things/+/shadow/update' WHERE isUndefined(state.desired) = false"
  sql_version = "2016-03-23"

  lambda {
    function_arn = aws_lambda_function.tuya_command.arn
  }

  tags = var.common_tags
}

# -----------------------------------------------------------------------------
# Secrets Manager for Tuya Credentials
# -----------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "tuya_credentials" {
  name                    = "${var.name_prefix}-tuya-credentials"
  description             = "Tuya Cloud API credentials"
  recovery_window_in_days = 0

  tags = var.common_tags
}

resource "aws_secretsmanager_secret_version" "tuya_credentials" {
  secret_id = aws_secretsmanager_secret.tuya_credentials.id
  secret_string = jsonencode({
    client_id     = var.tuya_client_id
    client_secret = var.tuya_client_secret
    region        = var.tuya_region
  })
}

# -----------------------------------------------------------------------------
# Lambda: Poll Tuya → Update IoT Core Shadows
# -----------------------------------------------------------------------------
resource "aws_lambda_function" "tuya_poller" {
  function_name = "${var.name_prefix}-tuya-poller"
  description   = "Polls Tuya Cloud and updates IoT Core device shadows"
  role          = aws_iam_role.lambda_role.arn
  handler       = "handler.poll_tuya_devices"
  runtime       = "python3.11"
  timeout       = 60
  memory_size   = 256

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      TUYA_DEVICE_IDS   = var.tuya_device_ids
      SECRET_NAME       = aws_secretsmanager_secret.tuya_credentials.name
      IOT_ENDPOINT      = data.aws_iot_endpoint.current.endpoint_address
    }
  }

  tags = var.common_tags
}

# EventBridge: Schedule polling every minute
resource "aws_cloudwatch_event_rule" "tuya_poll_schedule" {
  name                = "${var.name_prefix}-tuya-poll"
  description         = "Poll Tuya devices periodically"
  schedule_expression = "rate(1 minute)"

  tags = var.common_tags
}

resource "aws_cloudwatch_event_target" "tuya_poll_target" {
  rule      = aws_cloudwatch_event_rule.tuya_poll_schedule.name
  target_id = "TuyaPoller"
  arn       = aws_lambda_function.tuya_poller.arn
}

resource "aws_lambda_permission" "allow_eventbridge_poller" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.tuya_poller.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.tuya_poll_schedule.arn
}

# -----------------------------------------------------------------------------
# Lambda: Receive Commands → Send to Tuya
# -----------------------------------------------------------------------------
resource "aws_lambda_function" "tuya_command" {
  function_name = "${var.name_prefix}-tuya-command"
  description   = "Sends commands from IoT Core to Tuya devices"
  role          = aws_iam_role.lambda_role.arn
  handler       = "handler.send_command_to_tuya"
  runtime       = "python3.11"
  timeout       = 30
  memory_size   = 128

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      SECRET_NAME  = aws_secretsmanager_secret.tuya_credentials.name
      IOT_ENDPOINT = data.aws_iot_endpoint.current.endpoint_address
    }
  }

  tags = var.common_tags
}

resource "aws_lambda_permission" "allow_iot_command" {
  statement_id  = "AllowIoTRule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.tuya_command.function_name
  principal     = "iot.amazonaws.com"
}

# -----------------------------------------------------------------------------
# Timestream Database (Time-series metrics)
# -----------------------------------------------------------------------------
# NOTE: Timestream for LiveAnalytics is closed to new AWS customers as of 2025.
# Set enable_timestream = true only if your account has existing access.

resource "aws_timestreamwrite_database" "metrics" {
  count = var.enable_timestream ? 1 : 0

  database_name = replace("${var.name_prefix}_metrics", "-", "_")

  tags = var.common_tags
}

resource "aws_timestreamwrite_table" "device_telemetry" {
  count = var.enable_timestream ? 1 : 0

  database_name = aws_timestreamwrite_database.metrics[0].database_name
  table_name    = "device_telemetry"

  retention_properties {
    memory_store_retention_period_in_hours  = 24      # Hot storage: 24 hours
    magnetic_store_retention_period_in_days = 7       # Cold storage: 7 days
  }

  tags = var.common_tags
}

# IoT Rule: Telemetry → Timestream
resource "aws_iot_topic_rule" "telemetry_to_timestream" {
  count = var.enable_timestream ? 1 : 0

  name        = "${replace(var.name_prefix, "-", "_")}_telemetry"
  description = "Store device telemetry in Timestream"
  enabled     = true
  sql         = "SELECT state.reported.*, timestamp() as time FROM '$aws/things/+/shadow/update/accepted'"
  sql_version = "2016-03-23"

  timestream {
    database_name = aws_timestreamwrite_database.metrics[0].database_name
    table_name    = aws_timestreamwrite_table.device_telemetry[0].table_name
    role_arn      = aws_iam_role.iot_timestream_role[0].arn

    dimension {
      name  = "device_id"
      value = "$${topic(3)}"
    }
  }

  tags = var.common_tags
}

# -----------------------------------------------------------------------------
# CloudWatch Log Groups
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "tuya_poller" {
  name              = "/aws/lambda/${aws_lambda_function.tuya_poller.function_name}"
  retention_in_days = 7

  tags = var.common_tags
}

resource "aws_cloudwatch_log_group" "tuya_command" {
  name              = "/aws/lambda/${aws_lambda_function.tuya_command.function_name}"
  retention_in_days = 7

  tags = var.common_tags
}

# -----------------------------------------------------------------------------
# IAM Roles
# -----------------------------------------------------------------------------

# Lambda execution role
resource "aws_iam_role" "lambda_role" {
  name = "${var.name_prefix}-lambda-iot-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "${var.name_prefix}-lambda-iot-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = ["arn:aws:logs:*:*:*"]
      },
      {
        Effect = "Allow"
        Action = [
          "iot-data:UpdateThingShadow",
          "iot-data:GetThingShadow",
          "iot-data:Publish"
        ]
        Resource = ["*"]
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.tuya_credentials.arn]
      }
    ]
  })
}

# IoT → SQS role
resource "aws_iam_role" "iot_sqs_role" {
  name = "${var.name_prefix}-iot-sqs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "iot.amazonaws.com" }
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy" "iot_sqs_policy" {
  name = "${var.name_prefix}-iot-sqs-policy"
  role = aws_iam_role.iot_sqs_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:SendMessage"]
      Resource = [aws_sqs_queue.device_events.arn]
    }]
  })
}

# IoT → Timestream role (only created if Timestream is enabled)
resource "aws_iam_role" "iot_timestream_role" {
  count = var.enable_timestream ? 1 : 0

  name = "${var.name_prefix}-iot-timestream-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "iot.amazonaws.com" }
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy" "iot_timestream_policy" {
  count = var.enable_timestream ? 1 : 0

  name = "${var.name_prefix}-iot-timestream-policy"
  role = aws_iam_role.iot_timestream_role[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["timestream:WriteRecords", "timestream:DescribeEndpoints"]
      Resource = ["*"]
    }]
  })
}

# -----------------------------------------------------------------------------
# Lambda Deployment Package
# -----------------------------------------------------------------------------
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/lambda.zip"
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "iot_endpoint" {
  description = "AWS IoT Core endpoint"
  value       = data.aws_iot_endpoint.current.endpoint_address
}

output "device_events_queue_url" {
  description = "SQS queue URL for device events"
  value       = aws_sqs_queue.device_events.url
}

output "device_events_queue_arn" {
  description = "SQS queue ARN for device events"
  value       = aws_sqs_queue.device_events.arn
}

output "timestream_database" {
  description = "Timestream database name (null if disabled)"
  value       = try(aws_timestreamwrite_database.metrics[0].database_name, null)
}

output "timestream_table" {
  description = "Timestream table name (null if disabled)"
  value       = try(aws_timestreamwrite_table.device_telemetry[0].table_name, null)
}

output "tuya_poller_function" {
  description = "Tuya poller Lambda function name"
  value       = aws_lambda_function.tuya_poller.function_name
}

output "tuya_command_function" {
  description = "Tuya command Lambda function name"
  value       = aws_lambda_function.tuya_command.function_name
}
