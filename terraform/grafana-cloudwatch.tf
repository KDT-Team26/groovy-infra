# Grafana — AWS CloudWatch RDS 메트릭 조회를 위한 EKS Pod Identity 전용 IAM 역할.
# 최소 권한 원칙(Principle of Least Privilege)을 준수하여, 노드 전체가 아닌
# groovy-monitoring 네임스페이스의 grafana ServiceAccount에만 CloudWatch 읽기 권한을 격리 부여한다.

data "aws_iam_policy_document" "grafana_cloudwatch_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    actions = [
      "sts:AssumeRole",
      "sts:TagSession",
    ]
  }
}

resource "aws_iam_role" "grafana_cloudwatch" {
  name               = "groovy-grafana-cloudwatch-role"
  description        = "Allows Grafana pod to query CloudWatch metrics via EKS Pod Identity"
  assume_role_policy = data.aws_iam_policy_document.grafana_cloudwatch_assume_role.json
}

resource "aws_iam_role_policy_attachment" "grafana_cloudwatch" {
  role       = aws_iam_role.grafana_cloudwatch.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"
}

# groovy-monitoring/grafana ServiceAccount에 IAM 역할을 바인딩한다.
# Pod Identity 에이전트가 파드 기동 시 임시 자격증명을 컨테이너에 자동 주입한다.
resource "aws_eks_pod_identity_association" "grafana_cloudwatch" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "groovy-monitoring"
  service_account = "grafana"
  role_arn        = aws_iam_role.grafana_cloudwatch.arn
}
