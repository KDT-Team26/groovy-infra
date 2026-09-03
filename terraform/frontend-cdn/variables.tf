variable "project_name" {
  description = "Project name used for frontend resources."
  type        = string
  default     = "groovy"
}

variable "environment" {
  description = "Deployment environment."
  type        = string
  default     = "prod"
}

variable "domain_name" {
  description = "Route 53 hosted zone domain."
  type        = string
  default     = "groovy-team26.com"
}

variable "frontend_domain" {
  description = "Public frontend domain."
  type        = string
  default     = "www.groovy-team26.com"
}