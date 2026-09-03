# 프론트엔드 S3+CloudFront 정적 배포용 GitHub Actions CI가 assume하는 IAM 역할.
# groovy-github-actions-ecr-role(../github-actions-ecr.tf)과 동일한 패턴 — KDT-Team26 조직이
# OIDC subject claim에 조직/레포 numeric ID를 포함하도록 설정돼 있어서(CloudTrail로 이미 확인된
# 사실) sub 조건은 StringLike 와일드카드로 org/repo ID 부분만 허용한다.
data "aws_iam_policy_document" "github_actions_frontend_deploy_assume_role" {
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
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:KDT-Team26@*/groovy-frontend@*:ref:refs/heads/main",
      ]
    }
  }
}

# AWS IAM의 description 필드는 ASCII+Latin-1 범위만 허용해서 한글이 들어가면 CreateRole이
# ValidationError로 거부한다(#131에서 이미 겪은 문제) — description은 영어로 쓰고 설명은
# 이 주석에 한글로 남긴다.
resource "aws_iam_role" "github_actions_frontend_deploy" {
  name               = "groovy-github-actions-frontend-deploy-role"
  description        = "Assumed by GitHub Actions CI to deploy the frontend to S3 and invalidate CloudFront."
  assume_role_policy = data.aws_iam_policy_document.github_actions_frontend_deploy_assume_role.json
}

data "aws_iam_policy_document" "github_actions_frontend_deploy_permissions" {
  statement {
    effect = "Allow"
    actions = [
      "s3:ListBucket",
    ]
    resources = [aws_s3_bucket.frontend.arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.frontend.arn}/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["cloudfront:CreateInvalidation"]
    resources = ["arn:aws:cloudfront::${data.aws_caller_identity.current.account_id}:distribution/${aws_cloudfront_distribution.frontend.id}"]
  }
}

resource "aws_iam_policy" "github_actions_frontend_deploy" {
  name   = "groovy-github-actions-frontend-deploy-policy"
  policy = data.aws_iam_policy_document.github_actions_frontend_deploy_permissions.json
}

resource "aws_iam_role_policy_attachment" "github_actions_frontend_deploy" {
  role       = aws_iam_role.github_actions_frontend_deploy.name
  policy_arn = aws_iam_policy.github_actions_frontend_deploy.arn
}

output "github_actions_frontend_deploy_role_arn" {
  description = "groovy-frontend 레포의 GitHub Actions 워크플로(aws-actions/configure-aws-credentials)에 role-to-assume으로 넣을 ARN."
  value       = aws_iam_role.github_actions_frontend_deploy.arn
}
