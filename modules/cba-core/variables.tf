# ---------- identity ----------
variable "name" {
  description = "Application name. Also the ECS container name."
  type        = string
  default     = "cba-core"
}

variable "environment" {
  description = "Environment name (dev, uat, prod). Resources are named <name>-<environment>."
  type        = string
  default     = "dev"
}

# ---------- network (created by this module) ----------
variable "availability_zones" {
  description = "Two Availability Zones. If empty, the first two available zones are selected."
  type        = list(string)
  default     = []
  validation {
    condition     = length(var.availability_zones) == 0 || length(var.availability_zones) == 2
    error_message = "availability_zones must be empty or contain exactly two zones."
  }
}

variable "vpc_cidr" {
  description = "IPv4 range for the new application VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "One public subnet CIDR per selected AZ."
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]
  validation {
    condition     = length(var.public_subnet_cidrs) == 2
    error_message = "Provide exactly two public subnet CIDRs, one per Availability Zone."
  }
}

variable "private_subnet_cidrs" {
  description = "One private subnet CIDR per selected AZ."
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
  validation {
    condition     = length(var.private_subnet_cidrs) == 2
    error_message = "Provide exactly two private subnet CIDRs, one per Availability Zone."
  }
}

variable "nat_gateway_per_az" {
  description = "Create a NAT gateway in each AZ for resilient private subnet egress; false uses one shared NAT gateway."
  type        = bool
  default     = true
}

variable "enable_nat_gateways" {
  description = "Create NAT gateways for private subnet internet egress. Disable only when using suitable VPC endpoints or another egress path."
  type        = bool
  default     = true
}

variable "create_vpc_endpoints" {
  description = "Create VPC endpoints (ECR, Logs, Secrets Manager, SSM messages, S3) so tasks work without a NAT gateway."
  type        = bool
  default     = false
}

# ---------- ingress ----------
variable "acm_certificate_arn" {
  description = "ACM certificate (same region) for the ALB HTTPS listener."
  type        = string
}

variable "alb_ingress_cidrs" {
  description = "CIDRs allowed to reach the ALB on 80/443. Keep this tight for dev."
  type        = list(string)
}

variable "hostname" {
  description = "Optional DNS name for the ALB (needs route53_zone_id)."
  type        = string
  default     = null
}

variable "route53_zone_id" {
  description = "Optional hosted zone ID. When set together with hostname, an alias record is created."
  type        = string
  default     = null
}

# ---------- application ----------
variable "cors_allowed_origin_patterns" {
  description = "Value for FINERACT_SECURITY_CORS_ALLOWED_ORIGIN_PATTERNS, e.g. https://portal.example.com"
  type        = string
}

variable "tenant_timezone" {
  description = "Tenant timezone. Only applied the first time the tenant is created."
  type        = string
  default     = "Africa/Lagos"
}

variable "tenant_description" {
  type    = string
  default = "1UBank"
}

variable "enable_swagger" {
  description = "Swagger UI and /api-docs. Both default to ON in application.properties, so this module sets them explicitly."
  type        = bool
  default     = false
}

variable "extra_environment" {
  description = "Extra or overriding plain environment variables for the app container."
  type        = map(string)
  default     = {}
}

# ---------- ECS ----------
variable "cpu" {
  type    = number
  default = 2048
}

variable "memory" {
  type    = number
  default = 8192
}

variable "cpu_architecture" {
  description = "Must match the architecture the Jib image was built on."
  type        = string
  default     = "X86_64"

  validation {
    condition     = contains(["X86_64", "ARM64"], var.cpu_architecture)
    error_message = "cpu_architecture must be X86_64 or ARM64."
  }
}

variable "desired_count" {
  description = "Initial task count. Keep 0 for the first apply (no image in ECR yet). Terraform ignores later changes; scale with the CLI."
  type        = number
  default     = 1
}

variable "health_check_grace_period" {
  description = "Seconds ECS ignores ALB health checks after a task starts. First start runs all Liquibase migrations."
  type        = number
  default     = 900
}

variable "deployment_minimum_healthy_percent" {
  description = "0 avoids two versions running against one database (dev). Use 100 for rolling deploys once migrations are proven safe."
  type        = number
  default     = 0
}

variable "deployment_maximum_percent" {
  type    = number
  default = 100
}

variable "enable_execute_command" {
  description = "Enable ECS Exec (shell into a running task via SSM)."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "initial_image_tag" {
  description = "Tag in the first task definition revision. The pipeline replaces it on every deploy."
  type        = string
  default     = "bootstrap"
}

variable "ecr_tag_immutability" {
  description = "MUTABLE or IMMUTABLE. Consider IMMUTABLE for prod."
  type        = string
  default     = "MUTABLE"

  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE"], var.ecr_tag_immutability)
    error_message = "ecr_tag_immutability must be MUTABLE or IMMUTABLE."
  }
}

# ---------- database ----------
variable "db_engine_version" {
  description = "PostgreSQL version. Local dev uses 18.x; use it if RDS offers it in your region."
  type        = string
  default     = "17"
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.medium"
}

variable "db_allocated_storage" {
  type    = number
  default = 50
}

variable "db_max_allocated_storage" {
  type    = number
  default = 200
}

variable "db_master_username" {
  type    = string
  default = "cba_admin"
}

variable "db_multi_az" {
  type    = bool
  default = false
}

variable "db_backup_retention_days" {
  type    = number
  default = 7
}

variable "db_deletion_protection" {
  type    = bool
  default = false
}

variable "db_skip_final_snapshot" {
  type    = bool
  default = true
}

variable "db_init_image" {
  description = "Image for the one-off db-init task. Pulling it from ECR Public needs internet egress (NAT) - or mirror it into your own ECR."
  type        = string
  default     = "public.ecr.aws/docker/library/postgres:17-alpine"
}

# ---------- storage / secrets ----------
variable "s3_force_destroy" {
  type    = bool
  default = false
}

variable "secret_recovery_window_days" {
  type    = number
  default = 7
}

variable "web_image_tag" {
  description = "Tag of the web application image in the web ECR repository"
  type        = string
}

# ---------- cba-auth and cba-banking-api ----------
variable "auth_hostname" {
  description = "Public DNS name of the auth service (Keycloak), e.g. auth.dev.cba.1ubank.com. Must be covered by acm_certificate_arn. Becomes KC_HOSTNAME and the token issuer."
  type        = string
}

variable "banking_api_hostname" {
  description = "Public DNS name of the Banking API, e.g. api.dev.cba.1ubank.com. Must be covered by acm_certificate_arn."
  type        = string
}

variable "portal_url" {
  description = "Back-office portal URL given to the realm loader (PORTAL_URL). Defaults to https://<hostname>, or the ALB DNS name when no hostname is set."
  type        = string
  default     = null
}

variable "cba_core_api_url" {
  description = "CBA-CORE API as the auth service reaches it, e.g. https://<host>/fineract-provider/api/v1 (CBA_CORE_MIGRATION_API_URL). Must be https with a valid certificate. Leave null to skip the first-login migration setting for now."
  type        = string
  default     = null
}

variable "auth_block_admin_console" {
  description = "Return 403 on the public ALB for /admin/* and /realms/master/*. Set true wherever the ALB is open beyond a trusted CIDR list (prod)."
  type        = bool
  default     = false
}

variable "auth_cpu" {
  type    = number
  default = 1024
}

variable "auth_memory" {
  type    = number
  default = 2048
}

variable "auth_desired_count" {
  description = "Initial auth task count. Terraform ignores later changes."
  type        = number
  default     = 1
}

variable "auth_extra_environment" {
  description = "Extra or overriding plain environment variables for the auth container."
  type        = map(string)
  default     = {}
}

variable "realm_loader_username" {
  description = "Admin user the realm loader signs in as (master realm). The first start only has the bootstrap admin, so keep 'admin' until a dedicated realm-loader user exists."
  type        = string
  default     = "admin"
}

variable "banking_api_cpu" {
  type    = number
  default = 512
}

variable "banking_api_memory" {
  type    = number
  default = 1024
}

variable "banking_api_desired_count" {
  description = "Initial Banking API task count. Terraform ignores later changes."
  type        = number
  default     = 1
}

variable "banking_api_extra_environment" {
  description = "Extra or overriding plain environment variables for the Banking API container (for example the CBA-CORE client settings)."
  type        = map(string)
  default     = {}
}

variable "banking_api_sns_topic_arns" {
  description = "SNS topics the Banking API publishes events to. Gives its task role sns:Publish on them."
  type        = list(string)
  default     = []
}
