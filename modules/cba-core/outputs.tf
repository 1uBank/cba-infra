output "vpc_id" {
  value = local.vpc_id
}

output "public_subnet_ids" {
  value = local.public_subnet_ids
}

output "private_subnet_ids" {
  value = local.private_subnet_ids
}

output "private_route_table_ids" {
  value = local.private_route_table_ids
}

output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "ecr_repository_name" {
  value = aws_ecr_repository.app.name
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "ecs_service_name" {
  value = aws_ecs_service.app.name
}

output "task_family" {
  value = aws_ecs_task_definition.app.family
}

output "db_endpoint" {
  value = aws_db_instance.this.address
}

output "documents_bucket" {
  value = aws_s3_bucket.documents.bucket
}

output "app_secret_arn" {
  value = aws_secretsmanager_secret.app.arn
}

output "db_init_run_command" {
  description = "Run once after the first apply, before the first deploy."
  value       = <<-EOT
    aws ecs run-task --region ${local.region} --cluster ${aws_ecs_cluster.this.name} --launch-type FARGATE \
      --task-definition ${aws_ecs_task_definition.db_init.family} \
      --network-configuration "awsvpcConfiguration={subnets=[${join(",", local.private_subnet_ids)}],securityGroups=[${aws_security_group.tasks.id}],assignPublicIp=DISABLED}"
  EOT
}

output "scale_up_command" {
  description = "Run once after the pipeline has deployed the first image."
  value       = "aws ecs update-service --region ${local.region} --cluster ${aws_ecs_cluster.this.name} --service ${aws_ecs_service.app.name} --desired-count 1"
}

# ---------- cba-auth ----------
output "auth_ecr_repository_name" {
  value = aws_ecr_repository.auth.name
}

output "auth_realm_loader_ecr_repository_name" {
  value = aws_ecr_repository.auth_realm_loader.name
}

output "auth_service_name" {
  value = aws_ecs_service.auth.name
}

output "auth_task_family" {
  value = aws_ecs_task_definition.auth.family
}

output "auth_container_name" {
  value = local.auth_container_name
}

output "auth_realm_loader_task_family" {
  value = aws_ecs_task_definition.auth_realm_loader.family
}

output "auth_realm_loader_container_name" {
  value = local.auth_loader_container
}

output "auth_internal_url" {
  description = "Where the Banking API and the realm loader reach the auth service."
  value       = local.auth_internal_url
}

output "auth_secret_arn" {
  value = aws_secretsmanager_secret.auth.arn
}

output "auth_db_init_run_command" {
  description = "Run once after the first apply, before the first auth deploy."
  value       = <<-EOT
    aws ecs run-task --region ${local.region} --cluster ${aws_ecs_cluster.this.name} --launch-type FARGATE \
      --task-definition ${aws_ecs_task_definition.auth_db_init.family} \
      --network-configuration "awsvpcConfiguration={subnets=[${join(",", local.private_subnet_ids)}],securityGroups=[${aws_security_group.tasks.id}],assignPublicIp=DISABLED}"
  EOT
}

# ---------- cba-banking-api ----------
output "banking_api_ecr_repository_name" {
  value = aws_ecr_repository.banking_api.name
}

output "banking_api_service_name" {
  value = aws_ecs_service.banking_api.name
}

output "banking_api_task_family" {
  value = aws_ecs_task_definition.banking_api.family
}

output "banking_api_container_name" {
  value = local.banking_api_container_name
}

output "banking_api_secret_arn" {
  value = aws_secretsmanager_secret.banking_api.arn
}

output "banking_api_db_init_run_command" {
  description = "Run once after the first apply, before the first Banking API deploy."
  value       = <<-EOT
    aws ecs run-task --region ${local.region} --cluster ${aws_ecs_cluster.this.name} --launch-type FARGATE \
      --task-definition ${aws_ecs_task_definition.banking_api_db_init.family} \
      --network-configuration "awsvpcConfiguration={subnets=[${join(",", local.private_subnet_ids)}],securityGroups=[${aws_security_group.tasks.id}],assignPublicIp=DISABLED}"
  EOT
}

output "private_subnets_csv" {
  description = "Value for the GitHub variable PRIVATE_SUBNETS in cba-auth."
  value       = join(",", local.private_subnet_ids)
}

output "tasks_security_group_id" {
  description = "Value for the GitHub variable LOADER_SG in cba-auth."
  value       = aws_security_group.tasks.id
}
