# Registry Module Variables

variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "name_prefix" {
  type = string
}

variable "services" {
  description = "Map of service name -> service config. Only the keys are used here (one image per service)."
  type        = map(any)
}
