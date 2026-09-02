# External Secrets Operator(ESO) — groovy/* Secrets Manager 시크릿 읽기 전용 IAM 역할.
# 1단계(시크릿 연동을 Sealed Secrets/CSI Driver에서 ESO로 전환) 작업 중 콘솔/CLI로 먼저
# 만든 것을 코드로 반영한다. 이미 존재하는 리소스라 apply 전 terraform import 필요:
#   terraform import aws_iam_role.eso_secrets groovy-eso-secrets-role
#   terraform import aws_iam_policy.eso_secrets arn:aws:iam::665206375378:policy/groovy-eso-secrets-policy
#   terraform import aws_iam_role_policy_attachment.eso_secrets groovy-eso-secrets-role/arn:aws:iam::665206375378:policy/groovy-eso-secrets-policy
#   terraform import aws_eks_pod_identity_association.eso_secrets groovy-eks-cluster:<associationId>
#
# CSI Driver 시절엔 서비스마다 개별 역할(8개)을 뒀지만, ESO는 컨트롤러 하나가 대신 값을
# 가져와 각 네임스페이스에 일반 k8s Secret으로 동기화해주는 구조라 역할 1개로 충분하다.
# 실제로 어떤 서비스가 어떤 시크릿을 쓸지는 각 차트의 ExternalSecret 리소스가 개별 지정한다.

data "aws_iam_policy_document" "eso_secrets_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    actions = ["sts:AssumeRole", "sts:TagSession"]
  }
}

resource "aws_iam_role" "eso_secrets" {
  name               = "groovy-eso-secrets-role"
  assume_role_policy = data.aws_iam_policy_document.eso_secrets_assume_role.json
}

data "aws_iam_policy_document" "eso_secrets_permissions" {
  statement {
    effect = "Allow"

    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]

    # groovy/ 하위 전체 읽기 전용 — 이 계정 안의 다른 시크릿엔 접근 불가.
    resources = ["arn:aws:secretsmanager:ap-northeast-2:665206375378:secret:groovy/*"]
  }
}

resource "aws_iam_policy" "eso_secrets" {
  name   = "groovy-eso-secrets-policy"
  policy = data.aws_iam_policy_document.eso_secrets_permissions.json
}

resource "aws_iam_role_policy_attachment" "eso_secrets" {
  role       = aws_iam_role.eso_secrets.name
  policy_arn = aws_iam_policy.eso_secrets.arn
}

# external-secrets Helm 차트가 만드는 서비스어카운트(external-secrets/external-secrets)에
# 위 역할을 연결한다. Pod Identity는 파드가 "생성될 때" 자격증명을 주입하므로, 이 리소스가
# 바뀌면(예: 재import 등) 컨트롤러 파드를 재시작해야 반영된다.
resource "aws_eks_pod_identity_association" "eso_secrets" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.eso_secrets.arn
}
