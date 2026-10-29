resource "aws_db_subnet_group" "this" {
  name       = local.prefix
  subnet_ids = local.private_subnet_ids
}

resource "aws_db_instance" "this" {
  identifier     = local.prefix
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  storage_type          = "gp3"
  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_encrypted     = true

  # No initial database: the db-init task creates fineract_tenants / fineract_default
  # owned by the application role.
  username                    = var.db_master_username
  manage_master_user_password = true # RDS keeps the master password in Secrets Manager

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = var.db_multi_az

  backup_retention_period    = var.db_backup_retention_days
  copy_tags_to_snapshot      = true
  auto_minor_version_upgrade = true
  deletion_protection        = var.db_deletion_protection
  skip_final_snapshot        = var.db_skip_final_snapshot
  final_snapshot_identifier  = var.db_skip_final_snapshot ? null : "${local.prefix}-final"

  lifecycle {
    # Minor upgrades happen automatically; do major upgrades deliberately.
    ignore_changes = [engine_version]
  }
}
