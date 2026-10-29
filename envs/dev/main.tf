terraform {
  required_version = ">= 1.11" # use_lockfile (S3 native state locking)

  # Create this bucket by hand first (versioned, encrypted, private). See README step 1.
  backend "s3" {
    bucket       = "cba-deployment-bucket"
    key          = "cba-core/dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "cba-core"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}

module "cba_core" {
  source = "../../modules/cba-core"

  name        = "cba-core"
  environment = "dev"

  availability_zones      = var.availability_zones
  vpc_cidr                 = var.vpc_cidr
  public_subnet_cidrs      = var.public_subnet_cidrs
  private_subnet_cidrs     = var.private_subnet_cidrs
  nat_gateway_per_az       = var.nat_gateway_per_az
  enable_nat_gateways      = var.enable_nat_gateways
  create_vpc_endpoints    = var.create_vpc_endpoints
  web_image_tag           = var.web_image_tag
  acm_certificate_arn = var.acm_certificate_arn
  alb_ingress_cidrs   = var.alb_ingress_cidrs
  hostname            = var.hostname
  route53_zone_id     = var.route53_zone_id

  cors_allowed_origin_patterns = var.cors_allowed_origin_patterns

  # Dev-sized. For prod: cpu 4096 / memory 16384, db_multi_az = true,
  # db_deletion_protection = true, db_skip_final_snapshot = false,
  # deployment_minimum_healthy_percent = 100, deployment_maximum_percent = 200,
  # ecr_tag_immutability = "IMMUTABLE", enable_swagger = false.
}

# ---------- inputs ----------
variable "region" {
  type = string
}

variable "availability_zones" {
  description = "Two Availability Zones in region. Leave empty to use the first two available zones."
  type        = list(string)
  default     = []
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "nat_gateway_per_az" {
  description = "One NAT gateway per AZ improves resilience and avoids cross-AZ routing, at higher cost."
  type        = bool
  default     = true
}

variable "enable_nat_gateways" {
  description = "NAT gateway internet egress for private subnets."
  type        = bool
  default     = true
}

variable "create_vpc_endpoints" {
  type    = bool
  default = false
}

variable "acm_certificate_arn" {
  type = string
}

variable "alb_ingress_cidrs" {
  type = list(string)
}

variable "hostname" {
  type    = string
  default = null
}

variable "route53_zone_id" {
  type    = string
  default = null
}

variable "cors_allowed_origin_patterns" {
  type = string
}

variable "web_image_tag" {
  description = "Tag of the web image in the module's ECR repository"
  type        = string
}

# ---------- outputs ----------
output "vpc_id" {
  value = module.cba_core.vpc_id
}

output "public_subnet_ids" {
  value = module.cba_core.public_subnet_ids
}

output "private_subnet_ids" {
  value = module.cba_core.private_subnet_ids
}

output "private_route_table_ids" {
  value = module.cba_core.private_route_table_ids
}

output "alb_dns_name" {
  value = module.cba_core.alb_dns_name
}

output "ecr_repository_url" {
  value = module.cba_core.ecr_repository_url
}

output "db_endpoint" {
  value = module.cba_core.db_endpoint
}

output "documents_bucket" {
  value = module.cba_core.documents_bucket
}

output "db_init_run_command" {
  value = module.cba_core.db_init_run_command
}

output "scale_up_command" {
  value = module.cba_core.scale_up_command
}
