output "vpc_id" {
  description = "ID of the existing Groovy VPC."
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "IDs of the existing public subnets."
  value       = [for subnet in aws_subnet.public : subnet.id]
}

output "private_subnet_ids" {
  description = "IDs of the existing private subnets."
  value       = [for subnet in aws_subnet.private : subnet.id]
}

output "rds_subnet_ids" {
  description = "Private subnet IDs used by the existing RDS subnet group."
  value       = [for subnet in aws_subnet.private : subnet.id]
}

output "internet_gateway_id" {
  description = "ID of the existing Internet Gateway."
  value       = aws_internet_gateway.this.id
}

output "nat_gateway_id" {
  description = "ID of the existing Regional NAT Gateway."
  value       = aws_nat_gateway.this.id
}

output "eks_cluster_name" {
  description = "Name of the existing EKS cluster."
  value       = aws_eks_cluster.this.name
}

output "eks_cluster_endpoint" {
  description = "API endpoint of the existing EKS cluster."
  value       = aws_eks_cluster.this.endpoint
}

output "eks_node_group_name" {
  description = "Name of the existing EKS managed node group."
  value       = aws_eks_node_group.this.node_group_name
}

output "rds_endpoint" {
  description = "Endpoint of the existing RDS MySQL instance."
  value       = aws_db_instance.mysql.address
}

output "rds_port" {
  description = "Port of the existing RDS MySQL instance."
  value       = aws_db_instance.mysql.port
}

output "application_secret_arn" {
  description = "ARN of the existing application secret."
  value       = aws_secretsmanager_secret.application.arn
}

output "ecr_repository_urls" {
  description = "ECR repository URLs for the 6 backend services (frontend excluded — moving to S3+CloudFront in phase 6)."
  value       = { for name, repo in aws_ecr_repository.backend : name => repo.repository_url }
}