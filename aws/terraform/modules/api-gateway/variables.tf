# API Gateway Module Variables

variable "name_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "alb_dns_name" {
  type = string
}

variable "services" {
  type = map(any)
}

variable "common_tags" {
  type = map(string)
}
