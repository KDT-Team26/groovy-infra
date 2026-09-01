# EKS 클러스터 접근용 IAM 액세스 항목 — 2026-09-01, EKS 이관 작업 중 콘솔/CLI로 먼저
# 만든 것을 코드로 반영한다. 이미 실제로 존재하는 리소스라 바로 apply하면 "already exists"로
# 실패한다 — terraform import로 기존 리소스를 상태에 편입한 뒤 plan/apply할 것.
#   terraform import aws_eks_access_entry.groovy_tt groovy-eks-cluster:arn:aws:iam::665206375378:user/groovy_tt
#   terraform import aws_eks_access_entry.nodes groovy-eks-cluster:<groovy-eks-node-role ARN>

resource "aws_eks_access_entry" "groovy_tt" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = "arn:aws:iam::665206375378:user/groovy_tt"
}

resource "aws_eks_access_policy_association" "groovy_tt_admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.groovy_tt.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

# 노드 IAM 역할용 액세스 항목 — 이게 없으면 EC2는 뜨는데 노드가 클러스터에 조인하지 못한다.
resource "aws_eks_access_entry" "nodes" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.eks_nodes.arn
  type          = "EC2_LINUX"
}
