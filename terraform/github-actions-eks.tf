# 자동 롤백(auto-rollback P3) — deploy-verify.yml / rollback.yml 이 EKS API 로 ArgoCD
# Application·Deployment 상태를 "읽기"만 하기 위한 최소 권한 IAM 역할.
#
# 부여 범위:
#   - eks:DescribeCluster  : aws eks update-kubeconfig 용
#   - ecr:DescribeImages   : 롤백 목표 이미지가 ECR 에 실제 있는지 검증(rollback-core)
#   클러스터 내부 RBAC 은 argocd/bootstrap/ci-readonly-rbac.yaml 이 group=groovy-ci-readonly 에
#   get/list/watch 만 부여한다. write/exec 권한은 어디에도 없다.

data "aws_iam_policy_document" "github_actions_eks_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = ["arn:aws:iam::665206375378:oidc-provider/token.actions.githubusercontent.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # groovy-infra 레포에서만 assume. workflow_dispatch(rollback.yml)는 보통 main,
    # repository_dispatch(deploy-verify.yml)는 기본 브랜치(dev)에서 도므로 둘 다 허용.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:KDT-Team26@*/groovy-infra@*:ref:refs/heads/main",
        "repo:KDT-Team26@*/groovy-infra@*:ref:refs/heads/dev",
      ]
    }
  }
}

# IAM description 은 ASCII 만 허용 → 영어로.
# 역할 설명: GitHub Actions 자동 롤백 워크플로가 EKS/ECR 상태를 read-only 로 조회할 때 assume.
resource "aws_iam_role" "github_actions_eks_readonly" {
  name               = "groovy-github-actions-eks-readonly"
  description        = "Assumed by GitHub Actions auto-rollback workflows for read-only EKS/ECR status checks."
  assume_role_policy = data.aws_iam_policy_document.github_actions_eks_assume_role.json
}

data "aws_iam_policy_document" "github_actions_eks_readonly" {
  statement {
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = [aws_eks_cluster.this.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["ecr:DescribeImages"]
    resources = [for repo in aws_ecr_repository.backend : repo.arn]
  }
}

resource "aws_iam_policy" "github_actions_eks_readonly" {
  name   = "groovy-github-actions-eks-readonly-policy"
  policy = data.aws_iam_policy_document.github_actions_eks_readonly.json
}

resource "aws_iam_role_policy_attachment" "github_actions_eks_readonly" {
  role       = aws_iam_role.github_actions_eks_readonly.name
  policy_arn = aws_iam_policy.github_actions_eks_readonly.arn
}

# EKS 액세스 항목 — IAM 주체를 클러스터 내부 그룹 groovy-ci-readonly 로 매핑한다.
# 별도 access_policy_association 없이(AWS 관리형 정책 미사용) k8s RBAC 으로만 권한을 준다.
resource "aws_eks_access_entry" "github_actions_ci_readonly" {
  cluster_name      = aws_eks_cluster.this.name
  principal_arn     = aws_iam_role.github_actions_eks_readonly.arn
  kubernetes_groups = ["groovy-ci-readonly"]
  type              = "STANDARD"
}

output "github_actions_eks_readonly_role_arn" {
  description = "rollback.yml / deploy-verify.yml 의 configure-aws-credentials role-to-assume 에 넣을 ARN."
  value       = aws_iam_role.github_actions_eks_readonly.arn
}
