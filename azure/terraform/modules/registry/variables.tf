# Registry Module Variables

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "name_prefix" {
  type = string
}

variable "unique_suffix" {
  type = string
}

variable "services" {
  description = "Map of service name -> service config. Only the keys are used here (one image per service)."
  type        = map(any)
}

variable "tags" {
  type    = map(string)
  default = {}
}
