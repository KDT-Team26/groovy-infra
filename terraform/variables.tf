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
  default     = ["t4g.medium"]
  # 2026-09-03: t3.small -> t4g.medium. 노드당 최대 파드 11 -> 17, vCPU는 동일(2)이라
  # On-Demand vCPU 할당량(16) 안에서 8대 유지 시 88 -> 136자리로 늘어 필요한 101개를 커버함.
  # t4g는 Graviton(arm64)이므로 eks.tf의 ami_type도 AL2023_ARM_64_STANDARD로 함께 변경했다.
  # 서비스 이미지는 arm64 포함 멀티아치로 재빌드해 ECR에 푸시함(ArgoCD가 자동 배포).
}

variable "node_desired_size" {
  description = "Desired number configured on the existing EKS managed node group."
  type        = number
  default     = 5
  # 2026-09-03: t4g.medium 전환(node_instance_types 변경) 이후 재계산, 여유 없는 최소값.
  # 데몬셋을 제외한 워크로드 파드 수요는 HPA maxReplicas까지 다 찬 최악의 경우 51개,
  # 메모리 요청 합계는 약 13.8GiB. t4g.medium 1대의 워크로드 가용량은 파드 12자리
  # (max-pods 17에서 노드당 데몬셋 5개 제외), 메모리 약 3.1GiB(allocatable에서 데몬셋
  # 오버헤드 제외) — 파드 수 기준 51/12≈4.3, 메모리 기준 13.8/3.1≈4.5, 두 기준 모두
  # 충족하는 최소값은 5대(올림). 롤링 업데이트(max_unavailable=1) 여유분은 없으므로
  # 배포 중 일시적으로 파드가 Pending될 수 있음.
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
variable "domain_name" {
  description = "Registered public domain used by the Groovy platform."
  type        = string
  default     = "groovy-team26.com"
}
