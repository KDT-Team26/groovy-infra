resource "aws_kms_key" "secrets" {
  description             = "KMS key for Groovy application secrets"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = {
    Name = "${var.project_name}-${var.environment}-secrets"
  }
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.project_name}-${var.environment}-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

resource "aws_secretsmanager_secret" "application" {
  name                    = "${var.project_name}/${var.environment}/application"
  description             = "Groovy application secrets and database credentials"
  kms_key_id              = aws_kms_key.secrets.arn
  recovery_window_in_days = 7

  tags = {
    Name = "${var.project_name}-${var.environment}-application-secrets"
  }
}

resource "aws_secretsmanager_secret_version" "application" {
  secret_id     = aws_secretsmanager_secret.application.id
  secret_string = jsonencode(var.secret_values)
}

resource "aws_db_instance" "mysql" {
  identifier              = "${var.project_name}-${var.environment}-mysql"
  engine                  = "mysql"
  engine_version          = "8.0"
  instance_class          = var.db_instance_class
  allocated_storage       = var.db_allocated_storage
  storage_type            = "gp3"
  storage_encrypted       = true
  kms_key_id              = aws_kms_key.secrets.arn
  db_name                 = var.db_name
  username                = var.db_username
  password                = var.db_password
  port                    = 3306
  db_subnet_group_name    = aws_db_subnet_group.this.name
  vpc_security_group_ids  = [aws_security_group.rds.id]
  publicly_accessible     = false
  multi_az                = true
  skip_final_snapshot     = true
  deletion_protection     = false
  backup_retention_period = 7
  backup_window           = "18:00-19:00"
  maintenance_window      = "sun:19:00-sun:20:00"

  tags = {
    Name = "${var.project_name}-${var.environment}-mysql"
  }
}

locals {
  ecr_repositories = toset([
    "frontend",
    "api-gateway",
    "identity-service",
    "study-service",
    "content-service",
    "calendar-service",
    "notification-service",
  ])
}

resource "aws_ecr_repository" "application" {
  for_each = local.ecr_repositories

  name                 = "${var.project_name}/${each.key}"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.secrets.arn
  }

  tags = {
    Name = "${var.project_name}-${each.key}"
  }
}
