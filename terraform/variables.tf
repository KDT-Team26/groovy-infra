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
  default     = 10
  # 2026-09-02: t3.small(노드당 최대 파드 11개) 제약으로 실배포(2단계) 전체 파드가 못 뜨는
  # 문제 때문에 3 -> 10으로 임시 확장(ASG를 직접 조정, 노드그룹 자체가 CREATE_FAILED 상태로
  # 멈춰 있어 EKS 노드그룹 API로는 갱신이 안 돼서 aws autoscaling update-auto-scaling-group
  # 으로 우회함). 다음 팀 회의에서 인스턴스 타입 상향 등 정식 방향이 정해지면 이 값도 같이
  # 조정할 것 — 지금 값은 확정이 아니라 임시 조치.
}

variable "node_min_size" {
  description = "Current minimum number of EKS worker nodes."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Current maximum number of EKS worker nodes."
  type        = number
  default     = 10
}