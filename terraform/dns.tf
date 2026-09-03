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
    "ingress.k8s.aws/stack" = "istio-system/istio-ingressgateway"
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