# ---------------------------------------------------------------------------
# cba-auth (Keycloak) on the same cluster and ALB as cba-core.
#
# Routing:  Host = var.auth_hostname  -> auth service (port 8080)
#           /admin/* and /realms/master/* on that host -> 403 when
#           var.auth_block_admin_console is true
# Internal: cba-auth.<prefix>.internal:8080 (Cloud Map). The Banking API and the
#           realm loader use this address; it never leaves the VPC.
#
# Two ECS pieces:
#   - service  "<prefix>-auth"               long-running Keycloak
#   - task def "<prefix>-auth-realm-loader"  one-off run after each deploy
#   - task def "<prefix>-auth-db-init"       one-off, creates the database and role
#
# Requires: ecr.tf (aws_ecr_repository.auth, .auth_realm_loader), variables.tf,
#           rds.tf, iam.tf (exec role), alb.tf (HTTPS listener), ecs.tf (cluster)
# ---------------------------------------------------------------------------

locals {
  auth_container_name   = "cba-auth"
  auth_loader_container = "realm-loader"
  auth_port             = 8080
  auth_health_port      = 9000
  auth_db_user          = "auth"
  auth_db_name          = "auth"

  # Internal address used by the Banking API and the realm loader.
  auth_internal_url = "http://${aws_service_discovery_service.auth.name}.${aws_service_discovery_private_dns_namespace.this.name}:${local.auth_port}"

  portal_url = var.portal_url != null ? var.portal_url : (var.hostname != null ? "https://${var.hostname}" : "https://${aws_lb.this.dns_name}")

  auth_environment = merge(
    {
      KC_DB_URL      = "jdbc:postgresql://${aws_db_instance.this.address}:5432/${local.auth_db_name}?sslmode=require"
      KC_DB_USERNAME = local.auth_db_user

      # Public name: written into every token as the issuer. TLS ends at the ALB.
      KC_HOSTNAME      = "https://${var.auth_hostname}"
      KC_PROXY_HEADERS = "xforwarded"
      KC_HTTP_ENABLED  = "true"

      KC_BOOTSTRAP_ADMIN_USERNAME = "admin"
    },
    var.cba_core_api_url != null ? { CBA_CORE_MIGRATION_API_URL = var.cba_core_api_url } : {},
    var.auth_extra_environment,
  )

  auth_secrets = {
    KC_DB_PASSWORD              = "${aws_secretsmanager_secret.auth.arn}:DB_PASSWORD::"
    KC_BOOTSTRAP_ADMIN_PASSWORD = "${aws_secretsmanager_secret.auth.arn}:KC_BOOTSTRAP_ADMIN_PASSWORD::"
  }
}

# ---------- secrets ----------
resource "random_password" "auth_db" {
  length  = 32
  special = false
}

resource "random_password" "auth_bootstrap_admin" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "auth" {
  name                    = "${local.prefix}/auth"
  description             = "cba-auth secrets (${var.environment})"
  recovery_window_in_days = var.secret_recovery_window_days
}

resource "aws_secretsmanager_secret_version" "auth" {
  secret_id = aws_secretsmanager_secret.auth.id

  secret_string = jsonencode({
    DB_PASSWORD                 = random_password.auth_db.result
    KC_BOOTSTRAP_ADMIN_PASSWORD = random_password.auth_bootstrap_admin.result
    # The realm loader signs in with this. It starts as the bootstrap admin's password.
    # After you create a dedicated realm-loader user in the master realm, edit this
    # secret in the console and set realm_loader_username to match.
    REALM_LOADER_PASSWORD = random_password.auth_bootstrap_admin.result
  })

  lifecycle {
    # Console edits (the realm-loader password) must survive later applies.
    ignore_changes = [secret_string]
  }
}

data "aws_iam_policy_document" "exec_secrets_auth" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.auth.arn]
  }
}

resource "aws_iam_role_policy" "exec_secrets_auth" {
  name   = "read-secrets-auth"
  role   = aws_iam_role.exec.id
  policy = data.aws_iam_policy_document.exec_secrets_auth.json
}

# ---------- logs ----------
resource "aws_cloudwatch_log_group" "auth" {
  name              = "/ecs/${local.prefix}-auth"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "auth_realm_loader" {
  name              = "/ecs/${local.prefix}-auth-realm-loader"
  retention_in_days = var.log_retention_days
}

# ---------- service discovery (internal address) ----------
resource "aws_service_discovery_private_dns_namespace" "this" {
  name        = "${local.prefix}.internal"
  description = "Private service names for ${local.prefix}"
  vpc         = local.vpc_id
}

resource "aws_service_discovery_service" "auth" {
  name = "cba-auth"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.this.id
    routing_policy = "MULTIVALUE"

    dns_records {
      ttl  = 10
      type = "A"
    }
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

# ---------- task role ----------
resource "aws_iam_role" "auth_task" {
  name               = "${local.prefix}-auth-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy" "auth_task_exec" {
  count  = var.enable_execute_command ? 1 : 0
  name   = "ecs-exec"
  role   = aws_iam_role.auth_task.id
  policy = data.aws_iam_policy_document.task_exec_command.json
}

# ---------- db-init: creates the auth role and database (idempotent) ----------
locals {
  auth_db_init_script = <<-EOT
    set -eu
    psql -v ON_ERROR_STOP=1 -v app_pw="$APP_DB_PASSWORD" -d postgres <<'SQL'
    SELECT format('CREATE ROLE ${local.auth_db_user} LOGIN PASSWORD %L', :'app_pw')
      WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${local.auth_db_user}') \gexec
    GRANT ${local.auth_db_user} TO CURRENT_USER;
    SELECT 'CREATE DATABASE ${local.auth_db_name} OWNER ${local.auth_db_user}'
      WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${local.auth_db_name}') \gexec
    SQL
    echo "auth db-init finished"
  EOT
}

resource "aws_ecs_task_definition" "auth_db_init" {
  family                   = "${local.prefix}-auth-db-init"
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
    command     = [local.auth_db_init_script]
    environment = local.db_init_environment
    secrets = [
      { name = "PGPASSWORD", valueFrom = "${local.rds_master_secret_arn}:password::" },
      { name = "APP_DB_PASSWORD", valueFrom = "${aws_secretsmanager_secret.auth.arn}:DB_PASSWORD::" },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.db_init.name
        "awslogs-region"        = local.region
        "awslogs-stream-prefix" = "auth-db-init"
      }
    }
  }])
}

# ---------- Keycloak task definition ----------
resource "aws_ecs_task_definition" "auth" {
  family                   = "${local.prefix}-auth"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.auth_cpu)
  memory                   = tostring(var.auth_memory)
  execution_role_arn       = aws_iam_role.exec.arn
  task_role_arn            = aws_iam_role.auth_task.arn

  runtime_platform {
    cpu_architecture        = var.cpu_architecture
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([{
    name        = local.auth_container_name
    image       = "${aws_ecr_repository.auth.repository_url}:${var.initial_image_tag}"
    essential   = true
    stopTimeout = 60

    linuxParameters = { initProcessEnabled = true }

    portMappings = [
      { containerPort = local.auth_port, protocol = "tcp" },
      { containerPort = local.auth_health_port, protocol = "tcp" },
      { containerPort = 7800, protocol = "tcp" }, # Infinispan, only used with 2+ instances
    ]

    environment = [for k, v in local.auth_environment : { name = k, value = v }]
    secrets     = [for k, v in local.auth_secrets : { name = k, valueFrom = v }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.auth.name
        "awslogs-region"        = local.region
        "awslogs-stream-prefix" = "auth"
      }
    }
  }])
}

# ---------- realm loader task definition (no service: run once per deploy) ----------
resource "aws_ecs_task_definition" "auth_realm_loader" {
  family                   = "${local.prefix}-auth-realm-loader"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.exec.arn

  runtime_platform {
    cpu_architecture        = var.cpu_architecture
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([{
    name      = local.auth_loader_container
    image     = "${aws_ecr_repository.auth_realm_loader.repository_url}:${var.initial_image_tag}"
    essential = true

    environment = [
      { name = "IMPORT_FILES_LOCATIONS", value = "/config/*.yaml" },
      { name = "IMPORT_VARSUBSTITUTION_ENABLED", value = "true" },
      { name = "KEYCLOAK_AVAILABILITYCHECK_ENABLED", value = "true" },
      { name = "KEYCLOAK_AVAILABILITYCHECK_TIMEOUT", value = "180s" },
      { name = "KEYCLOAK_URL", value = local.auth_internal_url },
      { name = "KEYCLOAK_USER", value = var.realm_loader_username },
      { name = "PORTAL_URL", value = local.portal_url },
      { name = "CBA_CORE_MIGRATION_ENABLED", value = "true" },
    ]

    secrets = [
      { name = "KEYCLOAK_PASSWORD", valueFrom = "${aws_secretsmanager_secret.auth.arn}:REALM_LOADER_PASSWORD::" },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.auth_realm_loader.name
        "awslogs-region"        = local.region
        "awslogs-stream-prefix" = "realm-loader"
      }
    }
  }])
}

# ---------- target group and routing ----------
resource "aws_lb_target_group" "auth" {
  name                 = "${local.prefix}-auth"
  port                 = local.auth_port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = local.vpc_id
  deregistration_delay = 30

  # Keycloak serves health on the management port, not the traffic port.
  health_check {
    port                = tostring(local.auth_health_port)
    path                = "/health/ready"
    matcher             = "200"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 5
  }
}

# The admin console stays off the public ALB when var.auth_block_admin_console is true.
resource "aws_lb_listener_rule" "auth_block_admin" {
  count        = var.auth_block_admin_console ? 1 : 0
  listener_arn = aws_lb_listener.https.arn
  priority     = 5

  action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden"
      status_code  = "403"
    }
  }

  condition {
    host_header {
      values = [var.auth_hostname]
    }
  }

  condition {
    path_pattern {
      values = ["/admin/*", "/realms/master/*"]
    }
  }
}

resource "aws_lb_listener_rule" "auth" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 30

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.auth.arn
  }

  condition {
    host_header {
      values = [var.auth_hostname]
    }
  }
}

resource "aws_route53_record" "auth" {
  count   = var.route53_zone_id != null ? 1 : 0
  zone_id = var.route53_zone_id
  name    = var.auth_hostname
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}

# ---------- security groups ----------
# The existing rules open only port 8080 from the ALB. Keycloak health is on 9000.
resource "aws_vpc_security_group_egress_rule" "alb_to_auth_health" {
  security_group_id            = aws_security_group.alb.id
  description                  = "To auth health port"
  referenced_security_group_id = aws_security_group.tasks.id
  ip_protocol                  = "tcp"
  from_port                    = local.auth_health_port
  to_port                      = local.auth_health_port
}

resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb_auth_health" {
  security_group_id            = aws_security_group.tasks.id
  description                  = "Auth health port from ALB"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = local.auth_health_port
  to_port                      = local.auth_health_port
}

# Task-to-task traffic: Banking API -> auth, realm loader -> auth (8080).
resource "aws_vpc_security_group_ingress_rule" "tasks_self_app" {
  security_group_id            = aws_security_group.tasks.id
  description                  = "Service to service on the app port"
  referenced_security_group_id = aws_security_group.tasks.id
  ip_protocol                  = "tcp"
  from_port                    = local.auth_port
  to_port                      = local.auth_port
}

# Keycloak instances share sessions over 7800 when you run more than one.
resource "aws_vpc_security_group_ingress_rule" "tasks_self_keycloak_cluster" {
  security_group_id            = aws_security_group.tasks.id
  description                  = "Keycloak cluster traffic"
  referenced_security_group_id = aws_security_group.tasks.id
  ip_protocol                  = "tcp"
  from_port                    = 7800
  to_port                      = 7800
}

# ---------- service ----------
resource "aws_ecs_service" "auth" {
  name            = "${local.prefix}-auth"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.auth.arn
  desired_count   = var.auth_desired_count
  launch_type     = "FARGATE"

  health_check_grace_period_seconds  = 300
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
    target_group_arn = aws_lb_target_group.auth.arn
    container_name   = local.auth_container_name
    container_port   = local.auth_port
  }

  service_registries {
    registry_arn = aws_service_discovery_service.auth.arn
  }

  lifecycle {
    # The deploy pipeline owns the running task definition revision (image tag),
    # and you own the task count.
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [aws_lb_listener_rule.auth]
}
