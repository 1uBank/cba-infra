# NOTE: these values end up in Terraform state. Use an encrypted remote backend
# with restricted access (see envs/dev/main.tf).
#
# TENANT_MASTER_PASSWORD encrypts the tenant DB password stored inside the
# database. It must never change after the first start - do not taint or
# replace random_password.tenant_master.

resource "random_password" "db_app" {
  length  = 32
  special = false
}

resource "random_password" "tenant_master" {
  length  = 40
  special = false
}

resource "aws_secretsmanager_secret" "app" {
  name                    = "${local.prefix}/app"
  description             = "cba-core application secrets (${var.environment})"
  recovery_window_in_days = var.secret_recovery_window_days
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id

  secret_string = jsonencode({
    DB_PASSWORD            = random_password.db_app.result
    TENANT_MASTER_PASSWORD = random_password.tenant_master.result
  })
}
