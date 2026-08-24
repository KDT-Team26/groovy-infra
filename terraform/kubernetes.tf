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
    config = {
      corsAllowedOrigins = var.helm_cors_allowed_origins
    }
    identityService = {
      database = {
        host = aws_db_instance.mysql.address
      }
    }
    studyService = {
      database = {
        host = aws_db_instance.mysql.address
      }
    }
    contentService = {
      database = {
        host = aws_db_instance.mysql.address
      }
    }
    calendarService = {
      database = {
        host = aws_db_instance.mysql.address
      }
    }
    notificationService = {
      database = {
        host = aws_db_instance.mysql.address
      }
    }
    secret = {
      GF_SECURITY_ADMIN_PASSWORD = {
        password = lookup(var.secret_values, "grafana_admin_password", "CHANGE_ME")
      }
    }
  })]

  depends_on = [
    kubernetes_config_map_v1.runtime,
    kubernetes_service_account_v1.groovy
  ]
}
