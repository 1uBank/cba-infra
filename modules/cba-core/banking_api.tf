# ---------------------------------------------------------------------------
# cba-banking-api (Spring Boot) on the same cluster and ALB as cba-core.
#
# Routing:  Host = var.banking_api_hostname -> Banking API (port 8080)
# Health:   port 9001 /actuator/health/readiness (management port, not 8080)
# Database: database + role + schema "banking_api" on the module's RDS instance,
#           created by the one-off "<prefix>-banking-api-db-init" task.
#           Liquibase creates the tables on every start.
# Auth:     reaches cba-auth on its internal address (token URL and JWKS) and
#           validates tokens against the public issuer (see the README of
#           cba-banking-api, "The auth service's two addresses").
#
# Requires: auth.tf (service discovery, tasks self rule), ecr.tf
#           (aws_ecr_repository.banking_api), variables.tf, rds.tf, iam.tf,
#           alb.tf, ecs.tf
# ---------------------------------------------------------------------------

locals {
  banking_api_container_name = "cba-banking-api"
  banking_api_port           = 8080
  banking_api_health_port    = 9001
  banking_api_db_user        = "banking_api"
  banking_api_db_name        = "banking_api"
  banking_api_db_schema      = "banking_api"

  banking_api_environment = merge(
    {
      BANKING_API_DB_URL      = "jdbc:postgresql://${aws_db_instance.this.address}:5432/${local.banking_api_db_name}?sslmode=require"
      BANKING_API_DB_USERNAME = local.banking_api_db_user

      # Internal address: faster, never leaves the VPC.
      BANKING_API_AUTH_TOKEN_URL   = "${local.auth_internal_url}/realms/clients/protocol/openid-connect/token"
      BANKING_API_AUTH_JWK_SET_URI = "${local.auth_internal_url}/realms/clients/protocol/openid-connect/certs"

      # Public name: must equal KC_HOSTNAME of the auth service, or every token is rejected.
      BANKING_API_AUTH_ISSUER = "https://${var.auth_hostname}/realms/clients"
    },
    var.banking_api_extra_environment,
  )

  banking_api_secrets = {
    BANKING_API_DB_PASSWORD = "${aws_secretsmanager_secret.banking_api.arn}:DB_PASSWORD::"
  }
}

# ---------- secrets ----------
resource "random_password" "banking_api_db" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "banking_api" {
  name                    = "${local.prefix}/banking-api"
  description             = "cba-banking-api secrets (${var.environment})"
  recovery_window_in_days = var.secret_recovery_window_days
}

resource "aws_secretsmanager_secret_version" "banking_api" {
  secret_id = aws_secretsmanager_secret.banking_api.id

  secret_string = jsonencode({
    DB_PASSWORD = random_password.banking_api_db.result
  })
}

data "aws_iam_policy_document" "exec_secrets_banking_api" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.banking_api.arn]
  }
}

resource "aws_iam_role_policy" "exec_secrets_banking_api" {
  name   = "read-secrets-banking-api"
  role   = aws_iam_role.exec.id
  policy = data.aws_iam_policy_document.exec_secrets_banking_api.json
}

# ---------- logs ----------
resource "aws_cloudwatch_log_group" "banking_api" {
  name              = "/ecs/${local.prefix}-banking-api"
  retention_in_days = var.log_retention_days
}

# ---------- task role ----------
resource "aws_iam_role" "banking_api_task" {
  name               = "${local.prefix}-banking-api-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy" "banking_api_task_exec" {
  count  = var.enable_execute_command ? 1 : 0
  name   = "ecs-exec"
  role   = aws_iam_role.banking_api_task.id
  policy = data.aws_iam_policy_document.task_exec_command.json
}

# The events module publishes the outbox to SNS.
data "aws_iam_policy_document" "banking_api_sns" {
  count = length(var.banking_api_sns_topic_arns) > 0 ? 1 : 0

  statement {
    actions   = ["sns:Publish"]
    resources = var.banking_api_sns_topic_arns
  }
}

resource "aws_iam_role_policy" "banking_api_sns" {
  count  = length(var.banking_api_sns_topic_arns) > 0 ? 1 : 0
  name   = "publish-events"
  role   = aws_iam_role.banking_api_task.id
  policy = data.aws_iam_policy_document.banking_api_sns[0].json
}

# ---------- db-init: role, database and schema (idempotent) ----------
locals {
  banking_api_db_init_script = <<-EOT
    set -eu
    psql -v ON_ERROR_STOP=1 -v app_pw="$APP_DB_PASSWORD" -d postgres <<'SQL'
    SELECT format('CREATE ROLE ${local.banking_api_db_user} LOGIN PASSWORD %L', :'app_pw')
      WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${local.banking_api_db_user}') \gexec
    SELECT format('ALTER ROLE ${local.auth_db_user} WITH LOGIN PASSWORD %L', :'app_pw') \gexec
    GRANT ${local.banking_api_db_user} TO CURRENT_USER;
    SELECT 'CREATE DATABASE ${local.banking_api_db_name} OWNER ${local.banking_api_db_user}'
      WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${local.banking_api_db_name}') \gexec
    SQL
    psql -v ON_ERROR_STOP=1 -d ${local.banking_api_db_name} <<'SQL'
    CREATE SCHEMA IF NOT EXISTS ${local.banking_api_db_schema} AUTHORIZATION ${local.banking_api_db_user};
    SQL
    echo "banking-api db-init finished"
  EOT
}

resource "aws_ecs_task_definition" "banking_api_db_init" {
  family                   = "${local.prefix}-banking-api-db-init"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.exec.arn

  runtime_platform {
    cpu_architecture        = var.cpu_architecture
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([{
    name        = "db-init"
    image       = var.db_init_image
    essential   = true
    entryPoint  = ["sh", "-c"]
    command     = [local.banking_api_db_init_script]
    environment = local.db_init_environment
    secrets = [
      { name = "PGPASSWORD", valueFrom = "${local.rds_master_secret_arn}:password::" },
      { name = "APP_DB_PASSWORD", valueFrom = "${aws_secretsmanager_secret.banking_api.arn}:DB_PASSWORD::" },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.db_init.name
        "awslogs-region"        = local.region
        "awslogs-stream-prefix" = "banking-api-db-init"
      }
    }
  }])
}

# ---------- task definition ----------
resource "aws_ecs_task_definition" "banking_api" {
  family                   = "${local.prefix}-banking-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.banking_api_cpu)
  memory                   = tostring(var.banking_api_memory)
  execution_role_arn       = aws_iam_role.exec.arn
  task_role_arn            = aws_iam_role.banking_api_task.arn

  runtime_platform {
    cpu_architecture        = var.cpu_architecture
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([{
    name        = local.banking_api_container_name
    image       = "${aws_ecr_repository.banking_api.repository_url}:${var.initial_image_tag}"
    essential   = true
    stopTimeout = 30 # the app shuts down gracefully (server.shutdown: graceful)

    linuxParameters = { initProcessEnabled = true }

    portMappings = [
      { containerPort = local.banking_api_port, protocol = "tcp" },
      { containerPort = local.banking_api_health_port, protocol = "tcp" },
    ]

    environment = [for k, v in local.banking_api_environment : { name = k, value = v }]
    secrets     = [for k, v in local.banking_api_secrets : { name = k, valueFrom = v }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.banking_api.name
        "awslogs-region"        = local.region
        "awslogs-stream-prefix" = "banking-api"
      }
    }
  }])
}

# ---------- target group and routing ----------
resource "aws_lb_target_group" "banking_api" {
  name                 = "${local.prefix}-banking-api"
  port                 = local.banking_api_port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = local.vpc_id
  deregistration_delay = 30

  # Spring Boot serves actuator on the management port, not the traffic port.
  health_check {
    port                = tostring(local.banking_api_health_port)
    path                = "/actuator/health/readiness"
    matcher             = "200"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 5
  }
}

resource "aws_lb_listener_rule" "banking_api" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.banking_api.arn
  }

  condition {
    host_header {
      values = [var.banking_api_hostname]
    }
  }
}

resource "aws_route53_record" "banking_api" {
  count   = var.route53_zone_id != null ? 1 : 0
  zone_id = var.route53_zone_id
  name    = var.banking_api_hostname
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}

# ---------- security groups ----------
# Port 8080 from the ALB is already open. Health is on 9001.
resource "aws_vpc_security_group_egress_rule" "alb_to_banking_api_health" {
  security_group_id            = aws_security_group.alb.id
  description                  = "To Banking API health port"
  referenced_security_group_id = aws_security_group.tasks.id
  ip_protocol                  = "tcp"
  from_port                    = local.banking_api_health_port
  to_port                      = local.banking_api_health_port
}

resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb_banking_api_health" {
  security_group_id            = aws_security_group.tasks.id
  description                  = "Banking API health port from ALB"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = local.banking_api_health_port
  to_port                      = local.banking_api_health_port
}

# ---------- service ----------
resource "aws_ecs_service" "banking_api" {
  name            = "${local.prefix}-banking-api"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.banking_api.arn
  desired_count   = var.banking_api_desired_count
  launch_type     = "FARGATE"

  health_check_grace_period_seconds = 180
  # Liquibase runs on start. Keep these at the module defaults (stop-then-start in dev)
  # until your migrations are backward compatible, then use 100 / 200.
  deployment_minimum_healthy_percent = var.deployment_minimum_healthy_percent
  deployment_maximum_percent         = var.deployment_maximum_percent
  enable_execute_command             = var.enable_execute_command

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = local.private_subnet_ids
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.banking_api.arn
    container_name   = local.banking_api_container_name
    container_port   = local.banking_api_port
  }

  lifecycle {
    # The deploy pipeline owns the running task definition revision (image tag),
    # and you own the task count.
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [aws_lb_listener_rule.banking_api]
}
