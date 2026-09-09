# Cluster Autoscaler — 워크로드 부하 시 워커 노드를 자동 증설/축소하기 위한 EKS Pod Identity 전용 IAM 역할.
# 최소 권한 원칙(Principle of Least Privilege)을 적용하여:
# 1) 전체 노드가 아닌 kube-system/cluster-autoscaler ServiceAccount에만 임시 자격증명을 격리 주입한다.
# 2) SetDesiredCapacity / TerminateInstance 등 변경 권한은 당사 클러스터(groovy-eks-cluster) 소유 태그가 달린 ASG로 엄격히 한정한다.

data "aws_iam_policy_document" "cluster_autoscaler_assume_role" {
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

resource "aws_iam_role" "cluster_autoscaler" {
  name        = "groovy-cluster-autoscaler-role"
  description = "Allows Cluster Autoscaler pod to manage ASG capacity via EKS Pod Identity"

  assume_role_policy = data.aws_iam_policy_document.cluster_autoscaler_assume_role.json
}

data "aws_iam_policy_document" "cluster_autoscaler_permissions" {
  # 1. 메타데이터 및 ASG 조회 권한 (AWS API 제약상 Resource = ["*"] 필수)
  statement {
    sid    = "AutoscalingReadOnly"
    effect = "Allow"

    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeScalingActivities",
      "autoscaling:DescribeTags",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplateVersions",
    ]

    resources = ["*"]
  }

  # 2. 노드 증설/축소 변경 권한 — 오직 당사 EKS 클러스터 소유의 ASG로만 한정 (최소 권한 원칙)
  statement {
    sid    = "AutoscalingMutatingSpecificClusterOnly"
    effect = "Allow"

    actions = [
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/${aws_eks_cluster.this.name}"
      values   = ["owned"]
    }
  }
}

resource "aws_iam_policy" "cluster_autoscaler" {
  name        = "groovy-cluster-autoscaler-policy"
  description = "Scoped policy for Cluster Autoscaler to scale node groups of ${aws_eks_cluster.this.name}"
  policy      = data.aws_iam_policy_document.cluster_autoscaler_permissions.json
}

resource "aws_iam_role_policy_attachment" "cluster_autoscaler" {
  role       = aws_iam_role.cluster_autoscaler.name
  policy_arn = aws_iam_policy.cluster_autoscaler.arn
}

# kube-system/cluster-autoscaler ServiceAccount에 위 IAM 역할을 바인딩한다.
# EKS Pod Identity Agent가 파드 기동 시 임시 자격증명을 컨테이너에 자동 주입한다.
resource "aws_eks_pod_identity_association" "cluster_autoscaler" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "kube-system"
  service_account = "cluster-autoscaler"
  role_arn        = aws_iam_role.cluster_autoscaler.arn
}
