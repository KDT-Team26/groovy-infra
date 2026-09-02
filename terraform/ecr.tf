# 3단계(이미지 저장소 전환) — Docker Hub(ttt103/*) 대신 쓸 ECR 저장소. 6개 백엔드 서비스만
# 대상으로 한다 — frontend는 6단계(S3+CloudFront)에서 컨테이너 이미지 자체가 없어질 예정이라
# 지금 만들어봐야 곧 버려지므로 제외.
locals {
  ecr_repositories = toset([
    "groovy-gateway-service",
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

  # 커스텀 KMS 키가 코드로 관리되고 있지 않아(RDS의 kms_key_id는 리터럴 ARN 참조) 기본
  # AES256(AWS 관리형) 암호화를 쓴다 — 컨테이너 이미지 저장 용도에 KMS까지는 과함.
}

resource "aws_ecr_lifecycle_policy" "backend" {
  for_each   = aws_ecr_repository.backend
  repository = each.value.name

  # sha 태그 고정 정책상 이미지가 계속 쌓이기만 하므로, 오래된 것부터 자동 정리한다.
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "최근 20개만 보관, 나머지 만료"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 20
        }
        action = { type = "expire" }
      }
    ]
  })
}
