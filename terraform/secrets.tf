# 1단계(ESO 전환) 작업 중 AWS CLI로 먼저 만든 Secrets Manager 시크릿 컨테이너를 코드로
# 반영한다. 기존 aws_secretsmanager_secret.application(data.tf)과 동일하게 컨테이너만
# 선언하고 실제 값은 여기(코드)에 넣지 않는다 — 값 주입은 운영 절차로 별도 관리.
# 이미 존재하는 리소스라 apply 전 terraform import 필요:
#   terraform import aws_secretsmanager_secret.identity_jwt groovy/prod/identity-jwt
#   terraform import aws_secretsmanager_secret.kafka_exporter groovy/prod/kafka-exporter
#   terraform import 'aws_secretsmanager_secret.legacy_mysql["identity"]' groovy/legacy/mysql-identity
#   (study/content/calendar/notification도 동일하게 반복)

resource "aws_secretsmanager_secret" "identity_jwt" {
  name        = "groovy/prod/identity-jwt"
  description = "identity-service JWT 서명키(RSA, 전체 replica 공유). 로테이션 시 발급된 토큰 전부 무효화됨(#116)."

  lifecycle {
    ignore_changes = [force_overwrite_replica_secret, recovery_window_in_days]
  }
}

resource "aws_secretsmanager_secret" "kafka_exporter" {
  name        = "groovy/prod/kafka-exporter"
  description = "Kafka Exporter용 — groovy/prod/kafka의 app 계정 비밀번호를 그대로 재사용."

  lifecycle {
    ignore_changes = [force_overwrite_replica_secret, recovery_window_in_days]
  }
}

# 레거시 in-cluster MySQL(RDS 이관 후 롤백 경로로만 보존, groovy-infra#89 참고) 5개 인스턴스의
# root/provisioner 비밀번호.
resource "aws_secretsmanager_secret" "legacy_mysql" {
  for_each = toset(["identity", "study", "content", "calendar", "notification"])

  name        = "groovy/legacy/mysql-${each.key}"
  description = "레거시 in-cluster MySQL(${each.key}) root/provisioner 비밀번호 — RDS 롤백 경로 전용."

  lifecycle {
    ignore_changes = [force_overwrite_replica_secret, recovery_window_in_days]
  }
}

# groovy/prod/alertmanager, groovy/prod/argocd-notifications(둘 다 키: discordWebhookUrl)은
# 실제 Discord Webhook URL 값이 아직 없어 AWS에도 생성 안 된 상태 — 팀에서 값을 채워 넣을 때
# 이 파일에 같은 패턴으로 리소스를 추가할 것.
