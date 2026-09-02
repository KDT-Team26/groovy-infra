# 3단계(이미지 저장소 전환) — GitHub Actions가 ECR에 이미지를 push할 때 쓸 IAM 역할.
# 이 계정엔 이미 GitHub Actions용 OIDC 프로바이더(token.actions.githubusercontent.com)가
# 등록돼 있다(groovy-github-actions-ssm-role이 쓰던 것과 동일 — 그 역할 자체는 무관한
# 개인 레포(bebeghi/Test-groovy) 전용이라 재사용하지 않고 새로 만든다).
#
# 정적 AWS 액세스 키를 GitHub Secrets에 박아두는 대신 OIDC로 단기 자격증명을 받는 방식 —
# 지금 Docker Hub 로그인에 쓰는 DOCKERHUB_USERNAME/TOKEN 같은 장기 시크릿보다 안전하다.
# main 브랜치 push 트리거(현재 CI 조건과 동일)에서만 assume 가능하도록 sub 클레임을 6개
# 서비스 레포로 제한한다.

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

resource "aws_iam_role" "github_actions_ecr" {
  name               = "groovy-github-actions-ecr-role"
  description        = "GitHub Actions CI가 6개 백엔드 서비스 이미지를 ECR에 push할 때 assume하는 역할."
  assume_role_policy = data.aws_iam_policy_document.github_actions_ecr_assume_role.json
}

data "aws_iam_policy_document" "github_actions_ecr_permissions" {
  # GetAuthorizationToken은 리소스 레벨 권한을 지원하지 않아 반드시 "*"여야 한다(AWS 제약).
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
