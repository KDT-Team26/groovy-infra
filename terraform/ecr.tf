# 이미지 저장소를 Docker Hub에서 ECR로 전환한다.
locals {
  ecr_repositories = toset([
    "groovy-gateway-service", # 프론트엔드는 S3+CloudFront로 배포할 예정이라 저장소 생성 안함
    "groovy-identity-service",
    "groovy-study-service",
    "groovy-content-service",
    "groovy-calendar-service",
    "groovy-notification-service",
  ])
}

resource "aws_ecr_repository" "backend" {
  for_each = local.ecr_repositories

  name                 = each.key
  image_tag_mutability = "IMMUTABLE" # sha 태그만 쓰는 기존 CI 정책과 일치 — 같은 태그 덮어쓰기 방지

  image_scanning_configuration {
    scan_on_push = true
  }

}

resource "aws_ecr_lifecycle_policy" "backend" {
  for_each   = aws_ecr_repository.backend
  repository = each.value.name

  # sha 태그 고정 정책상 이미지가 계속 쌓이기만 하므로, 오래된 것부터 자동 정리한다.
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "최근 5개만 보관, 나머지 만료"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 5
        }
        action = { type = "expire" }
      }
    ]
  })
}
