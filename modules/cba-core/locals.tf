data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  prefix         = "${var.name}-${var.environment}"
  account_id     = data.aws_caller_identity.current.account_id
  region         = data.aws_region.current.name
  container_name = var.name
  app_port       = 8080
  health_path    = "/fineract-provider/actuator/health/readiness"

  db_app_user = "fineract_app"
  tenants_db  = "fineract_tenants"
  default_db  = "fineract_default"

  # From the repo's config/docker/env/fineract.env, minus the jdwp debug agent,
  # -Xmx1G and TieredStopAtLevel=1. The Jib image bakes in no JVM flags.
  java_tool_options = join(" ", [
    "-XX:MaxRAMPercentage=70",
    "--add-exports=java.naming/com.sun.jndi.ldap=ALL-UNNAMED",
    "--add-opens=java.base/java.lang=ALL-UNNAMED",
    "--add-opens=java.base/java.lang.invoke=ALL-UNNAMED",
    "--add-opens=java.base/java.io=ALL-UNNAMED",
    "--add-opens=java.base/java.security=ALL-UNNAMED",
    "--add-opens=java.base/java.util=ALL-UNNAMED",
    "--add-opens=java.management/javax.management=ALL-UNNAMED",
    "--add-opens=java.naming/javax.naming=ALL-UNNAMED",
  ])

  app_environment = merge(
    {
      FINERACT_SERVER_SSL_ENABLED = "false"
      FINERACT_SERVER_PORT        = tostring(local.app_port)

      FINERACT_HIKARI_JDBC_URL = "jdbc:postgresql://${aws_db_instance.this.address}:5432/${local.tenants_db}?sslmode=require"
      FINERACT_HIKARI_USERNAME = local.db_app_user

      FINERACT_DEFAULT_TENANTDB_HOSTNAME    = aws_db_instance.this.address
      FINERACT_DEFAULT_TENANTDB_PORT        = "5432"
      FINERACT_DEFAULT_TENANTDB_UID         = local.db_app_user
      FINERACT_DEFAULT_TENANTDB_NAME        = local.default_db
      FINERACT_DEFAULT_TENANTDB_IDENTIFIER  = "default"
      FINERACT_DEFAULT_TENANTDB_TIMEZONE    = var.tenant_timezone
      FINERACT_DEFAULT_TENANTDB_DESCRIPTION = var.tenant_description
      FINERACT_DEFAULT_TENANTDB_CONN_PARAMS = "sslmode=require"

      FINERACT_SECURITY_CORS_ALLOWED_ORIGIN_PATTERNS    = var.cors_allowed_origin_patterns
      FINERACT_INSECURE_HTTP_CLIENT                     = "false"
      FINERACT_MANAGEMENT_ENDPOINT_WEB_EXPOSURE_INCLUDE = "health,info,prometheus"

      FINERACT_CONTENT_FILESYSTEM_ENABLED = "false"
      FINERACT_CONTENT_S3_ENABLED         = "true"
      FINERACT_CONTENT_S3_BUCKET_NAME     = aws_s3_bucket.documents.bucket
      FINERACT_CONTENT_S3_REGION          = local.region

      SPRINGDOC_API_DOCS_ENABLED   = tostring(var.enable_swagger)
      SPRINGDOC_SWAGGER_UI_ENABLED = tostring(var.enable_swagger)

      JAVA_TOOL_OPTIONS = local.java_tool_options
    },
    var.extra_environment,
  )

  app_secrets = {
    FINERACT_HIKARI_PASSWORD                  = "${aws_secretsmanager_secret.app.arn}:DB_PASSWORD::"
    FINERACT_DEFAULT_TENANTDB_PWD             = "${aws_secretsmanager_secret.app.arn}:DB_PASSWORD::"
    FINERACT_DEFAULT_TENANTDB_MASTER_PASSWORD = "${aws_secretsmanager_secret.app.arn}:TENANT_MASTER_PASSWORD::"
    FINERACT_DEFAULT_MASTER_PASSWORD          = "${aws_secretsmanager_secret.app.arn}:TENANT_MASTER_PASSWORD::"
  }

  rds_master_secret_arn = aws_db_instance.this.master_user_secret[0].secret_arn
}
