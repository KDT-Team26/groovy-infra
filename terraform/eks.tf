resource "aws_eks_cluster" "this" {
  name     = "groovy-eks-cluster"
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.cluster_version

  vpc_config {
    subnet_ids = [
      aws_subnet.private["a"].id,
      aws_subnet.private["b"].id,
    ]

    endpoint_public_access  = true
    endpoint_private_access = true
  }

  enabled_cluster_log_types = [
    "api",
    "audit",
    "authenticator",
  ]

  zonal_shift_config {
    enabled = false
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy
  ]
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "groovy-eks-node-group"
  node_role_arn   = aws_iam_role.eks_nodes.arn

  subnet_ids = [
    aws_subnet.private["a"].id,
    aws_subnet.private["b"].id,
  ]

  version         = "1.36"
  release_version = "1.36.3-20260827"
  ami_type        = "AL2023_ARM_64_STANDARD"
  capacity_type   = "ON_DEMAND"
  disk_size       = 20
  instance_types  = var.node_instance_types

  scaling_config {
    min_size     = var.node_min_size
    desired_size = var.node_desired_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
    update_strategy = "DEFAULT"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node,
    aws_iam_role_policy_attachment.eks_cni,
    aws_iam_role_policy_attachment.ecr_read_only
  ]
}

resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/groovy-eks-cluster/cluster"
  retention_in_days = 0
}