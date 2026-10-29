# ---------------------------------------------------------------------------
# cba-web-app (Angular portal) on the same cluster and ALB as cba-core.
#
# Routing:  /fineract-provider/*  -> cba-core   (port 8080)
#           everything else        -> web app    (port 80)
# Same domain, so the browser needs no CORS to reach the API.
#
# Requires:
#   - aws_ecr_repository.web                (ecr.tf)
#   - variable "web_image_tag"              (variables.tf)
#   - alb.tf: change the HTTPS listener's default_action to forward to
#     aws_lb_target_group.web.arn (see the note at the bottom of this file)
# ---------------------------------------------------------------------------

locals {
  web_container_name = "cba-web-app"
  web_port           = 80
}

resource "aws_cloudwatch_log_group" "web" {
  name              = "/ecs/${local.prefix}-web"
  retention_in_days = var.log_retention_days
}

# ---------- task definition ----------
resource "aws_ecs_task_definition" "web" {
  family                   = "${local.prefix}-web"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.exec.arn
  task_role_arn            = aws_iam_role.web_task.arn

  runtime_platform {
    cpu_architecture        = var.cpu_architecture
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([{
    name         = local.web_container_name
    image        = "${aws_ecr_repository.web.repository_url}:${var.web_image_tag}"
    essential    = true
    stopTimeout  = 30
    portMappings = [{ containerPort = local.web_port, protocol = "tcp" }]

    # These end up in assets/env.js, which anyone who opens the portal can read.
    # Never put secrets here. FINERACT_API_URL is intentionally unset: the app then
    # calls the same origin, and the ALB routes /fineract-provider/* to cba-core.
    environment = [
      { name = "FINERACT_PLATFORM_TENANT_IDENTIFIER", value = "default" },
      { name = "MIFOS_ALLOW_SERVER_SWITCH_SELECTOR", value = "false" },
      { name = "MIFOS_DISPLAY_TENANT_SELECTOR", value = "false" },
      { name = "MIFOS_DISPLAY_BACKEND_INFO", value = "true" }, # set "false" for production
      { name = "MIFOS_PRODUCTION_MODE_ENABLE_RBAC", value = "true" },
      { name = "MIFOS_SESSION_IDLE_TIMEOUT", value = "900000" },
      { name = "MIFOS_DEFAULT_LANGUAGE", value = "en-US" },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.web.name
        "awslogs-region"        = local.region
        "awslogs-stream-prefix" = "web"
      }
    }
  }])
}

# ---------- target group and routing ----------
resource "aws_lb_target_group" "web" {
  name                 = "${local.prefix}-web"
  port                 = local.web_port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = aws_security_group.tasks.vpc_id
  deregistration_delay = 30

  health_check {
    path                = "/"
    matcher             = "200"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# API traffic keeps going to cba-core. Priority 10 is evaluated before the
# listener's default action (the web app).
resource "aws_lb_listener_rule" "api" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  condition {
    path_pattern {
      values = ["/fineract-provider/*"]
    }
  }
}

# ---------- security groups ----------
# The existing rules only open port 8080. The web app listens on 80, so both the
# ALB (egress) and the tasks (ingress) need a port 80 rule. Without these the
# health checks time out and the target stays unhealthy.
resource "aws_vpc_security_group_egress_rule" "alb_to_web" {
  security_group_id            = aws_security_group.alb.id
  description                  = "To web tasks"
  referenced_security_group_id = aws_security_group.tasks.id
  ip_protocol                  = "tcp"
  from_port                    = local.web_port
  to_port                      = local.web_port
}

resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb_web" {
  security_group_id            = aws_security_group.tasks.id
  description                  = "Web port from ALB"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = local.web_port
  to_port                      = local.web_port
}

# ---------- service ----------
resource "aws_ecs_service" "web" {
  name            = "${local.prefix}-web"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.web.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  health_check_grace_period_seconds  = 60
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
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
    target_group_arn = aws_lb_target_group.web.arn
    container_name   = local.web_container_name
    container_port   = local.web_port
  }

  lifecycle {
    # The deploy pipeline owns the running task definition revision (image tag).
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [aws_lb_listener_rule.api]
}

resource "aws_iam_role" "web_task" {
  name = "${local.prefix}-web-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "web_task_exec" {
  count = var.enable_execute_command ? 1 : 0
  name  = "${local.prefix}-web-task-exec"
  role  = aws_iam_role.web_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel"
      ]
      Resource = "*"
    }]
  })
}