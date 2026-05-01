# ECS Module Variables

variable "name_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "services" {
  type = map(object({
    port        = number
    cpu         = number
    memory      = number
    health_path = string
    owner       = string
  }))
}

variable "db_endpoint" {
  type = string
}

variable "db_name" {
  type    = string
  default = "smarthome"
}

variable "iot_endpoint" {
  type = string
}

variable "device_events_queue" {
  type = string
}

variable "common_tags" {
  type = map(string)
}
