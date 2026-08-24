output "vpc_id" {
  value = aws_vpc.this.id
}

output "private_subnet_ids" {
  value = [for subnet in aws_subnet.private : subnet.id]
}

output "database_subnet_ids" {
  value = [for subnet in aws_subnet.database : subnet.id]
}

output "eks_cluster_name" {
  value = aws_eks_cluster.this.name
}

output "eks_cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "rds_endpoint" {
  value = aws_db_instance.mysql.address
}

output "rds_port" {
  value = aws_db_instance.mysql.port
}

output "ecr_repository_urls" {
  value = {
    for name, repository in aws_ecr_repository.application : name => repository.repository_url
  }
}

output "application_secret_arn" {
  value = aws_secretsmanager_secret.application.arn
}

output "kms_key_arn" {
  value = aws_kms_key.secrets.arn
}

output "kubernetes_namespace" {
  value = kubernetes_namespace_v1.groovy.metadata[0].name
}

output "helm_release_name" {
  value = helm_release.groovy.name
}
