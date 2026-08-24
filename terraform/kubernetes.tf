variable "kubernetes_namespace" {
  description = "Namespace for the Groovy Helm release and Terraform-managed platform objects."
  type        = string
  default     = "groovy"
}

variable "helm_release_name" {
  description = "Helm release name for the Groovy MSA chart."
  type        = string
  default     = "groovy-msa"
}

resource "kubernetes_namespace_v1" "groovy" {
  metadata {
    name = var.kubernetes_namespace

    labels = {
      "app.kubernetes.io/part-of" = var.project_name
      environment                 = var.environment
    }
  }
}

resource "kubernetes_service_account_v1" "groovy" {
  metadata {
    name      = "${var.project_name}-workload"
    namespace = kubernetes_namespace_v1.groovy.metadata[0].name

    labels = {
      "app.kubernetes.io/part-of" = var.project_name
    }
  }
}

resource "kubernetes_config_map_v1" "runtime" {
  metadata {
    name      = "${var.project_name}-terraform-runtime"
    namespace = kubernetes_namespace_v1.groovy.metadata[0].name

    labels = {
      "app.kubernetes.io/part-of"    = var.project_name
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  data = {
    AWS_REGION                 = var.aws_region
    RDS_HOST                   = aws_db_instance.mysql.address
    RDS_PORT                   = tostring(aws_db_instance.mysql.port)
    RDS_SECRET_ARN             = aws_secretsmanager_secret.application.arn
    OTLP_TRACING_ENDPOINT      = "http://tempo:4318/v1/traces"
    KUBERNETES_SERVICE_ACCOUNT = kubernetes_service_account_v1.groovy.metadata[0].name
  }
}

resource "helm_release" "groovy" {
  name              = var.helm_release_name
  namespace         = kubernetes_namespace_v1.groovy.metadata[0].name
  create_namespace  = false
  chart             = "${path.module}/../helm/groovy"
  dependency_update = false
  wait              = true
  timeout           = 900
  cleanup_on_fail   = true

  values = [yamlencode({
    frontend = {
      image = {
        repository = aws_ecr_repository.application["frontend"].repository_url
      }
    }
    apiGateway = {
      image = {
        repository = aws_ecr_repository.application["api-gateway"].repository_url
      }
    }
    config = {
      corsAllowedOrigins = var.helm_cors_allowed_origins
    }
    identityService = {
      image = {
        repository = aws_ecr_repository.application["identity-service"].repository_url
      }
      database = {
        host = aws_db_instance.mysql.address
      }
    }
    studyService = {
      image = {
        repository = aws_ecr_repository.application["study-service"].repository_url
      }
      database = {
        host = aws_db_instance.mysql.address
      }
    }
    contentService = {
      image = {
        repository = aws_ecr_repository.application["content-service"].repository_url
      }
      database = {
        host = aws_db_instance.mysql.address
      }
    }
    calendarService = {
      image = {
        repository = aws_ecr_repository.application["calendar-service"].repository_url
      }
      database = {
        host = aws_db_instance.mysql.address
      }
    }
    notificationService = {
      image = {
        repository = aws_ecr_repository.application["notification-service"].repository_url
      }
      database = {
        host = aws_db_instance.mysql.address
      }
    }
    secret = {
      mysqlRootPassword = lookup(var.secret_values, "mysql_root_password", "CHANGE_ME")
      identityService = {
        dbPassword = lookup(var.secret_values, "identity_db_password", "CHANGE_ME")
      }
      studyService = {
        dbPassword = lookup(var.secret_values, "study_db_password", "CHANGE_ME")
      }
      contentService = {
        dbPassword = lookup(var.secret_values, "content_db_password", "CHANGE_ME")
      }
      calendarService = {
        dbPassword = lookup(var.secret_values, "calendar_db_password", "CHANGE_ME")
      }
      notificationService = {
        dbPassword = lookup(var.secret_values, "notification_db_password", "CHANGE_ME")
      }
      kafka = {
        brokerPassword      = lookup(var.secret_values, "kafka_broker_password", "CHANGE_ME")
        applicationPassword = lookup(var.secret_values, "kafka_application_password", "CHANGE_ME")
      }
      grafanaAdminPassword = lookup(var.secret_values, "grafana_admin_password", "CHANGE_ME")
    }
  })]

  depends_on = [
    kubernetes_config_map_v1.runtime,
    kubernetes_service_account_v1.groovy
  ]
}
