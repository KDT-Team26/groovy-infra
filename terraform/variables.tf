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
  description = "CIDR block of the existing Groovy VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones used by the existing VPC."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count == 2
    error_message = "The existing Groovy VPC currently uses two availability zones."
  }
}

variable "cluster_version" {
  description = "Current Kubernetes version of the Groovy EKS cluster."
  type        = string
  default     = "1.36"
}

variable "node_instance_types" {
  description = "Current EKS managed node group instance type."
  type        = list(string)
  default     = ["t3.small"]
}

variable "node_desired_size" {
  description = "Desired number configured on the existing EKS managed node group."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Current minimum number of EKS worker nodes."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Current maximum number of EKS worker nodes."
  type        = number
  default     = 3
}