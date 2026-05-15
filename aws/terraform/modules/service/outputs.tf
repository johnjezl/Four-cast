output "url" {
  description = "Public URL for this service. Every AWS service shares the ALB; path-based routing dispatches on /api/v1/<name>."
  value       = "http://${var.alb_dns_name}/api/v1/${replace(var.service_name, "-service", "")}"
}

output "target_group_arn" {
  value = aws_lb_target_group.this.arn
}

output "ecr_repository_url" {
  value = aws_ecr_repository.this.repository_url
}

output "task_definition_arn" {
  value = aws_ecs_task_definition.this.arn
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.this.name
}
