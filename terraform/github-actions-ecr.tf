# # 이미지 저장소를 Docker Hub에서 ECR로 전환할 때, GitHub Actions가 ECR에 이미지를 push할 때 쓸 IAM 역할.

data "aws_iam_policy_document" "github_actions_ecr_assume_role" {
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

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:KDT-Team26/groovy-gateway-service:ref:refs/heads/main",
        "repo:KDT-Team26/groovy-identity-service:ref:refs/heads/main",
        "repo:KDT-Team26/groovy-study-service:ref:refs/heads/main",
        "repo:KDT-Team26/groovy-content-service:ref:refs/heads/main",
        "repo:KDT-Team26/groovy-calendar-service:ref:refs/heads/main",
        "repo:KDT-Team26/groovy-notification-service:ref:refs/heads/main",
      ]
    }
  }
}

# AWS IAM의 description 필드는 ASCII+Latin-1 범위만 허용해서 한글이 들어가면 CreateRole이
# ValidationError로 거부한다 — 그래서 description은 영어로 쓰고 설명은 이 주석에 한글로 남긴다.
# 역할 설명: GitHub Actions CI가 6개 백엔드 서비스 이미지를 ECR에 push할 때 assume하는 역할.
resource "aws_iam_role" "github_actions_ecr" {
  name               = "groovy-github-actions-ecr-role"
  description        = "Assumed by GitHub Actions CI to push backend service images to ECR."
  assume_role_policy = data.aws_iam_policy_document.github_actions_ecr_assume_role.json
}

data "aws_iam_policy_document" "github_actions_ecr_permissions" {
  # GetAuthorizationToken은 리소스 레벨 권한을 지원하지 않아 반드시 "*"여야 함(AWS 제약
  statement {
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = [for repo in aws_ecr_repository.backend : repo.arn]
  }
}

resource "aws_iam_policy" "github_actions_ecr" {
  name   = "groovy-github-actions-ecr-policy"
  policy = data.aws_iam_policy_document.github_actions_ecr_permissions.json
}

resource "aws_iam_role_policy_attachment" "github_actions_ecr" {
  role       = aws_iam_role.github_actions_ecr.name
  policy_arn = aws_iam_policy.github_actions_ecr.arn
}

output "github_actions_ecr_role_arn" {
  description = "6개 서비스 레포의 GitHub Actions 워크플로(aws-actions/configure-aws-credentials)에 role-to-assume으로 넣을 ARN."
  value       = aws_iam_role.github_actions_ecr.arn
}
