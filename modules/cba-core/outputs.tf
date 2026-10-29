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
