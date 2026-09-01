resource "aws_secretsmanager_secret" "application" {
  name = "${var.project_name}/${var.environment}/application"

  # Secret 값과 삭제 관련 기본 설정은 별도 운영 절차로 관리한다.
  lifecycle {
    ignore_changes = [
      force_overwrite_replica_secret,
      recovery_window_in_days
    ]
  }
}

resource "aws_db_instance" "mysql" {
  identifier        = "groovy-rds-mysql"
  engine            = "mysql"
  engine_version    = "8.4.9"
  instance_class    = "db.t4g.micro"
  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  kms_key_id = "arn:aws:kms:ap-northeast-2:665206375378:key/69e8390b-33ac-4018-8821-890ac5ae88cf"

  username = "groovyadmin"
  port     = 3306

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  publicly_accessible     = false
  multi_az                = false
  deletion_protection     = false
  backup_retention_period = 1
  skip_final_snapshot     = true

  lifecycle {
    ignore_changes = [
      apply_immediately
    ]
  }
}

# ECR 저장소 생성은 CI/CD 및 이미지 배포 단계에서 별도 진행한다.