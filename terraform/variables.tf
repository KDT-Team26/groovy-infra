variable "aws_region" {
  description = "AWS region for the Groovy platform."
  type        = string
  default     = "ap-northeast-2"
}

variable "project_name" {
  description = "Project name used in resource names and tags."
  type        = string
  default     = "groovy"
}

variable "environment" {
  description = "Deployment environment."
  type        = string
  default     = "prod"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones used by the VPC."
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be between 2 and 3."
  }
}

variable "cluster_version" {
  description = "EKS Kubernetes version."
  type        = string
  default     = "1.31"
}

variable "node_instance_types" {
  description = "Managed node group instance types."
  type        = list(string)
  default     = ["t3.large"]
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "db_name" {
  type    = string
  default = "identity_db"
}

variable "db_username" {
  type    = string
  default = "groovy_admin"
}

variable "db_password" {
  description = "RDS master password. Supply via TF_VAR_db_password or a tfvars file excluded from source control."
  type        = string
  sensitive   = true
  default     = null
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.medium"
}

variable "db_allocated_storage" {
  type    = number
  default = 50
}

variable "secret_values" {
  description = "Optional application secrets stored as JSON in Secrets Manager."
  type        = map(string)
  sensitive   = true
  default     = {}
}

variable "helm_cors_allowed_origins" {
  description = "Allowed browser origins passed to the Helm chart."
  type        = string
  default     = "https://CHANGE_ME.example.com"
}
