# Groovy AWS infrastructure

This directory provisions the AWS foundation for the Groovy MSA in `ap-northeast-2`:

- VPC with public, private, and isolated database subnets across 2-3 AZs
- Internet Gateway and one NAT Gateway per AZ
- EKS cluster and managed node group
- IAM roles and AWS-managed policies for EKS
- ECR repositories for the frontend and six backend services
- Private, encrypted, Multi-AZ RDS MySQL
- KMS key, Secrets Manager secret, and EKS CloudWatch log group
- Kubernetes and Helm providers authenticated from the EKS cluster

Before applying, provide a real `db_password` and application values through variables. The secret version is intentionally backed by `secret_values`; do not commit a tfvars file containing credentials.

The current Helm chart still expects service DNS names such as `mysql`, `redis`, `kafka`, and `tempo`. This stack provisions RDS MySQL only. Redis, Kafka, observability components, a public ingress/load balancer, and External Secrets integration remain deployment prerequisites.
