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
  default     = 8
  # 2026-09-02: t3.small(노드당 최대 파드 11개) 제약으로 실배포(2단계) 전체 파드(약 101개)가
  # 못 뜨는 문제 때문에 3 -> 10으로 임시 확장 시도(ASG를 직접 조정, 노드그룹 자체가
  # CREATE_FAILED 상태로 멈춰 있어 EKS 노드그룹 API로는 갱신이 안 돼서
  # aws autoscaling update-auto-scaling-group으로 우회함). 계정의 On-Demand vCPU 할당량
  # (16, t3.small 기준 8대)에 막혀 8대에서 정지 — 9번째부터 VcpuLimitExceeded로 계속 실패.
  # 8대(88자리)로는 필요 101개에 13개 부족해 일부 파드가 Pending으로 남을 수 있음, 다음
  # 팀 회의에서 vCPU 할당량 상향 또는 인스턴스 타입 조정 등 정식 방향 논의 예정 — 임시 조치.
}

variable "node_min_size" {
  description = "Current minimum number of EKS worker nodes."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Current maximum number of EKS worker nodes."
  type        = number
  default     = 8
}