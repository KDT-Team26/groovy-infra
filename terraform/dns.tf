resource "aws_route53_zone" "primary" {
  name          = var.domain_name
  comment       = "Public hosted zone for the Groovy platform."
  force_destroy = false

  tags = {
    Name        = "${var.project_name}-${var.environment}-dns"
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_acm_certificate" "api" {
  domain_name       = "api.${var.domain_name}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-api-certificate"
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_route53_record" "api_certificate_validation" {
  allow_overwrite = true
  zone_id         = aws_route53_zone.primary.zone_id
  name            = tolist(aws_acm_certificate.api.domain_validation_options)[0].resource_record_name
  type            = tolist(aws_acm_certificate.api.domain_validation_options)[0].resource_record_type
  ttl             = 60
  records = [
    tolist(aws_acm_certificate.api.domain_validation_options)[0].resource_record_value
  ]
}

resource "aws_acm_certificate_validation" "api" {
  certificate_arn = aws_acm_certificate.api.arn
  validation_record_fqdns = [
    aws_route53_record.api_certificate_validation.fqdn
  ]
}

# elbv2.k8s.aws/cluster 태그만으로는 이 클러스터에 ALB가 여러 개일 때 조회가 모호해져
# apply가 깨진다. ingress.k8s.aws/stack은 <namespace>/<ingress 이름> 형식이라 Ingress
# 리소스별로 고유하므로 이것으로 특정 ALB만 콕 집는다. api-gateway(Spring Cloud Gateway)를
# Istio ingress gateway로 대체(4단계)하면서 이 값도 istio 쪽 Ingress로 바꿨다 —
# helm/istio-gateway/templates/ingress.yaml 참고.
data "aws_lb" "api_gateway" {
  tags = {
    "elbv2.k8s.aws/cluster" = "groovy-eks-cluster"
    "ingress.k8s.aws/stack" = "groovy-shared-alb"
  }
}

resource "aws_route53_record" "api" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = "api.${var.domain_name}"
  type    = "A"

  alias {
    name                   = "dualstack.${data.aws_lb.api_gateway.dns_name}"
    zone_id                = data.aws_lb.api_gateway.zone_id
    evaluate_target_health = true
  }
}

# ArgoCD 웹훅(#193 B안) + ArgoCD UI + 그라파나 UI 외부 노출 — 셋 다 같은 ALB를
# IngressGroup으로 공유한다(argocd.groovy-team26.com, grafana.groovy-team26.com).
#
# ⚠️ 미완성/미적용 상태. 아래 리소스는 helm/istio-gateway 의 albGroupName 설정,
# argocd/bootstrap/argocd-ingress.yaml, helm/observability(그라파나 Ingress) 적용과 세트로
# 묶여 있다 — 순서를 지키지 않으면 data.aws_lb.api_gateway 조회가 깨지거나(태그값이 그룹명으로
# 바뀌므로) 이 레코드들이 가리킬 ALB가 없는 상태로 apply될 수 있다. 적용 순서는
# docs/argocd-webhook-setup.md 참고.
#
# 순서 요약:
#   1) helm/istio-gateway/values.yaml + helm/observability/values.yaml 의 albGroupName을
#      동일한 값으로 설정 + 각 Ingress의 certificate-arn을 아래 인증서 발급 후 채움
#   2) 세 Ingress(istio-gateway/argocd/grafana)를 반영 → AWS Load Balancer Controller가
#      그룹으로 재구성 → ALB의 ingress.k8s.aws/stack 태그가 albGroupName 값으로 바뀌는 것을
#      콘솔/CLI로 확인
#   3) 그제서야 아래 data.aws_lb.api_gateway 의 태그 필터 값을 albGroupName 으로 갱신
#   4) terraform apply (이 파일의 신규 리소스 + 3번 변경 함께)
resource "aws_acm_certificate" "argocd" {
  domain_name       = "argocd.${var.domain_name}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-argocd-certificate"
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_route53_record" "argocd_certificate_validation" {
  allow_overwrite = true
  zone_id         = aws_route53_zone.primary.zone_id
  name            = tolist(aws_acm_certificate.argocd.domain_validation_options)[0].resource_record_name
  type            = tolist(aws_acm_certificate.argocd.domain_validation_options)[0].resource_record_type
  ttl             = 60
  records = [
    tolist(aws_acm_certificate.argocd.domain_validation_options)[0].resource_record_value
  ]
}

resource "aws_acm_certificate_validation" "argocd" {
  certificate_arn = aws_acm_certificate.argocd.arn
  validation_record_fqdns = [
    aws_route53_record.argocd_certificate_validation.fqdn
  ]
}

resource "aws_route53_record" "argocd" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = "argocd.${var.domain_name}"
  type    = "A"

  alias {
    name                   = "dualstack.${data.aws_lb.api_gateway.dns_name}"
    zone_id                = data.aws_lb.api_gateway.zone_id
    evaluate_target_health = true
  }
}

resource "aws_acm_certificate" "grafana" {
  domain_name       = "grafana.${var.domain_name}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-grafana-certificate"
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_route53_record" "grafana_certificate_validation" {
  allow_overwrite = true
  zone_id         = aws_route53_zone.primary.zone_id
  name            = tolist(aws_acm_certificate.grafana.domain_validation_options)[0].resource_record_name
  type            = tolist(aws_acm_certificate.grafana.domain_validation_options)[0].resource_record_type
  ttl             = 60
  records = [
    tolist(aws_acm_certificate.grafana.domain_validation_options)[0].resource_record_value
  ]
}

resource "aws_acm_certificate_validation" "grafana" {
  certificate_arn = aws_acm_certificate.grafana.arn
  validation_record_fqdns = [
    aws_route53_record.grafana_certificate_validation.fqdn
  ]
}

resource "aws_route53_record" "grafana" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = "grafana.${var.domain_name}"
  type    = "A"

  alias {
    name                   = "dualstack.${data.aws_lb.api_gateway.dns_name}"
    zone_id                = data.aws_lb.api_gateway.zone_id
    evaluate_target_health = true
  }
}