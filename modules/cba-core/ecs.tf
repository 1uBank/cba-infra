resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${local.prefix}"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "db_init" {
  name              = "/ecs/${local.prefix}-db-init"
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_cluster" "this" {
  name = local.prefix

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# ---------- db-init: creates the app role and the two databases (idempotent) ----------
# Used in two places:
#   1. As a non-essential init container inside the app task definition. ECS runs it
#      first on every task start and only starts cba-core if it exits 0.
#   2. As a standalone task definition for manual run-task (debugging, first bootstrap).
locals {
  db_init_script = <<-EOT
    set -eu
    psql -v ON_ERROR_STOP=1 -v app_pw="$APP_DB_PASSWORD" -d postgres <<'SQL'
    SELECT format('CREATE ROLE ${local.db_app_user} LOGIN PASSWORD %L', :'app_pw')
      WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${local.db_app_user}') \gexec
    GRANT ${local.db_app_user} TO CURRENT_USER;
    SELECT 'CREATE DATABASE ${local.tenants_db} OWNER ${local.db_app_user}'
      WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${local.tenants_db}') \gexec
    SELECT 'CREATE DATABASE ${local.default_db} OWNER ${local.db_app_user}'
      WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${local.default_db}') \gexec
    SQL
    echo "db-init finished"
  EOT

  db_init_environment = [
    { name = "PGHOST", value = aws_db_instance.this.address },
    { name = "PGPORT", value = "5432" },
    { name = "PGUSER", value = var.db_master_username },
    { name = "PGSSLMODE", value = "require" },
    # Fail fast instead of hanging if RDS is unreachable (security group / routing).
    { name = "PGCONNECT_TIMEOUT", value = "15" },
  ]

  db_init_secrets = [
    { name = "PGPASSWORD", valueFrom = "${local.rds_master_secret_arn}:password::" },
    { name = "APP_DB_PASSWORD", valueFrom = "${aws_secretsmanager_secret.app.arn}:DB_PASSWORD::" },
  ]

  db_init_log_configuration = {
    logDriver = "awslogs"
    options = {
      "awslogs-group"         = aws_cloudwatch_log_group.db_init.name
      "awslogs-region"        = local.region
      "awslogs-stream-prefix" = "db-init"
    }
  }
}

# ---------- application task definition ----------
resource "aws_ecs_task_definition" "app" {
  family                   = local.prefix
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.cpu)
  memory                   = tostring(var.memory)
  execution_role_arn       = aws_iam_role.exec.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    cpu_architecture        = var.cpu_architecture
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([
    # Init container: runs first, creates the role/databases if missing, then exits.
    # essential = false is required: otherwise its normal exit would stop the whole task.
    {
      name         = "db-init"
      image        = var.db_init_image
      essential    = false
      startTimeout = 180 # give up (and fail the task) if db-init has not finished in time
      entryPoint   = ["sh", "-c"]
      command      = [local.db_init_script]

      environment      = local.db_init_environment
      secrets          = local.db_init_secrets
      logConfiguration = local.db_init_log_configuration
    },
    {
      name        = local.container_name
      image       = "${aws_ecr_repository.app.repository_url}:${var.initial_image_tag}"
      essential   = true
      stopTimeout = 120

      # Do not start the app until db-init exited with code 0.
      dependsOn = [
        { containerName = "db-init", condition = "SUCCESS" }
      ]

      linuxParameters = { initProcessEnabled = true }

      portMappings = [{
        containerPort = local.app_port
        protocol      = "tcp"
      }]

      environment = [for k, v in local.app_environment : { name = k, value = v }]
      secrets     = [for k, v in local.app_secrets : { name = k, valueFrom = v }]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = local.region
          "awslogs-stream-prefix" = "app"
        }
      }
    }
  ])
}

resource "aws_ecs_task_definition" "db_init" {
  family                   = "${local.prefix}-db-init"
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
    name             = "db-init"
    image            = var.db_init_image
    essential        = true
    entryPoint       = ["sh", "-c"]
    command          = [local.db_init_script]
    environment      = local.db_init_environment
    secrets          = local.db_init_secrets
    logConfiguration = local.db_init_log_configuration
  }])
}

# ---------- service ----------
resource "aws_ecs_service" "app" {
  name            = local.prefix
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  health_check_grace_period_seconds  = var.health_check_grace_period
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
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = local.container_name
    container_port   = local.app_port
  }

  lifecycle {
    # The CI/CD pipeline owns the running task definition revision (image tag),
    # and you own the task count. Terraform must not fight either.
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [aws_lb_listener.https]
}
