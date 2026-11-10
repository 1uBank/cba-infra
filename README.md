# Terraform deployment runbook

This Terraform configuration deploys the CBA Core backend and Angular frontend on
AWS. The frontend is an additional ECS task definition and service in the **same
ECS cluster** as the backend. Both services use the same VPC and Application Load
Balancer (ALB):

| Request path | ALB destination |
|---|---|
| `/fineract-provider/*` | Backend service, port 8080 |
| All other paths | Frontend service, port 80 |

Use the existing Terraform root and state for this environment when updating an
already-deployed stack. Do not initialize a new state key to add the frontend:
Terraform would no longer know about the existing cluster and could attempt to
create a second stack.

## What is in this folder

- `envs/dev/` — root Terraform configuration and inputs for the dev environment.
- `modules/cba-core/` — VPC, ALB, ECS cluster and services, ECR repositories,
  RDS, S3, IAM, secrets, and security groups.
- `bootstrap/github-oidc/` — separate Terraform root for GitHub Actions OIDC
  access to deploy the backend without stored AWS access keys.

## Prerequisites

- Terraform 1.11 or later.
- AWS CLI v2 and Docker, configured with credentials for the target AWS account.
- Permission to create and manage the resources in this stack. The deployment
  identity needs access to the Terraform state bucket as well.
- An ACM certificate that is issued in the same AWS region as the ALB.
- A frontend Docker image that listens on port 80 and serves the portal.
- A GitHub repository and workflow for the backend deployment, if using the
  supplied OIDC setup.

Check which account and region your AWS CLI will use:

```powershell
aws sts get-caller-identity
aws configure get region
```

The examples below use `us-east-1`, matching the checked-in dev configuration.
Keep the provider region, backend region, ACM certificate region, and image
repository region consistent.

## Deployment sequence

### 1. Prepare the Terraform state bucket

The state bucket must exist before `terraform init`. The current backend blocks
in `envs/dev/main.tf` and `bootstrap/github-oidc/main.tf` use the bucket
`cba-deployment-bucket` in `us-east-1`, with different state keys. If you use a
different bucket or region, update both backend blocks before initializing.

Create the bucket once if it does not already exist. For `us-east-1`:

```powershell
aws s3api create-bucket --bucket cba-deployment-bucket --region us-east-1
```

For another region, add its location constraint:

```powershell
aws s3api create-bucket --bucket <unique-bucket-name> --region <region> --create-bucket-configuration LocationConstraint=<region>
```

Enable versioning, encryption, and public-access blocking:

```powershell
aws s3api put-bucket-versioning --bucket cba-deployment-bucket --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket cba-deployment-bucket --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket cba-deployment-bucket --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

Terraform state contains infrastructure details and generated database passwords.
Restrict bucket access to trusted operators and the deployment role.

### 2. Configure and review the dev environment

Open `envs/dev/main.tf` and confirm the S3 backend bucket, key, and region point
to the existing dev state. The key should remain
`cba-core/dev/terraform.tfstate` for the existing stack.

Review `envs/dev/terraform.tfvars` (or copy
`envs/dev/terraform.tfvars.example` to that filename). Set:

- `region` and non-overlapping VPC/subnet CIDRs.
- `acm_certificate_arn` for an issued certificate in that region.
- `alb_ingress_cidrs` to the public IP ranges that should reach the ALB. Avoid
  `0.0.0.0/0` unless public access is intentional.
- `cors_allowed_origin_patterns`. With same-origin frontend requests this can
  normally be limited to the portal's HTTPS origin; avoid `*` unless needed.
- Optional `hostname` and `route53_zone_id` together, if Terraform should
  create a DNS alias.
- `web_image_tag`, which must match the tag you push to the web ECR repository.

The module creates its own VPC, public/private subnets, and NAT gateways. Do not
provide existing subnet IDs as inputs to this configuration.

### 3. Plan and apply the infrastructure

From the Terraform directory:

```powershell
Set-Location .\envs\dev
terraform init
terraform validate
terraform plan -out dev.tfplan
terraform show dev.tfplan
```

Review the plan before applying. When updating an existing deployment, the plan
should retain the existing ECS cluster and backend service and add/update the
web resources. **Stop if the plan unexpectedly replaces or destroys the VPC,
cluster, backend service, or database.** Confirm the workspace, backend key,
variables, and state before proceeding.

Apply the reviewed plan:

```powershell
terraform apply dev.tfplan
```

This creates the web ECR repository and its task definition/service in the
existing cluster. The web service is configured to run one task and initially
references `web_image_tag`. If that image has not yet been pushed, its task
cannot start. Push the image in the next step, then force a fresh deployment if
ECS has not started it automatically.

The backend service starts with a desired count of zero by default. It remains
stopped until the backend image has been deployed and the database bootstrap has
completed.

### 4. Build and push the frontend image

The Terraform repository does not contain the frontend build workflow. Build the
frontend image using its own Dockerfile and build context. Run the Docker build
from the frontend folder containing its Dockerfile, and set the tag to the same
value as `web_image_tag` in `envs/dev/terraform.tfvars`.

The following PowerShell commands assume the standard name `cba-core-dev-web`:

```powershell
$Region = "us-east-1"
$AccountId = (aws sts get-caller-identity --query Account --output text).Trim()
$Registry = "$AccountId.dkr.ecr.$Region.amazonaws.com"
$Repository = "$Registry/cba-core-dev-web"
$WebTag = "latest"

aws ecr get-login-password --region $Region | docker login --username AWS --password-stdin $Registry
docker build -t "${Repository}:${WebTag}" .
docker push "${Repository}:${WebTag}"
```

The frontend must send API calls to a same-origin path such as
`/fineract-provider/...`. Do not bake in `localhost` or the private ECS task
address. The ALB sends those API paths to the backend service.

If the web service did not start after the image was pushed, ask ECS to retry:

```powershell
aws ecs update-service --region $Region --cluster cba-core-dev --service cba-core-dev-web --force-new-deployment
```

For later frontend releases, push a new tag and update `web_image_tag` in the
Terraform variables before running `terraform plan` and `terraform apply` again.
If reusing a mutable tag such as `latest`, force a new ECS deployment after
pushing it so ECS pulls the updated image.

### 5. Initialize the application databases once

Wait until RDS is available. Run the generated one-off task from PowerShell:

```powershell
$Region = "us-east-1"
$Cluster = "cba-core-dev"
$Subnets = (terraform output -json private_subnet_ids | ConvertFrom-Json) -join ","
$SecurityGroup = (aws ec2 describe-security-groups --region $Region --filters "Name=group-name,Values=cba-core-dev-tasks" --query "SecurityGroups[0].GroupId" --output text).Trim()
$Network = "awsvpcConfiguration={subnets=[$Subnets],securityGroups=[$SecurityGroup],assignPublicIp=DISABLED}"

aws ecs run-task --region $Region --cluster $Cluster --launch-type FARGATE --task-definition cba-core-dev-db-init --network-configuration $Network
```

Check the task result and the `/ecs/cba-core-dev-db-init` CloudWatch log group for
`db-init finished`. This task creates the application role and databases. It is
idempotent, but the initial bootstrap only needs to be run once.

### 6. (Optional) Configure GitHub Actions OIDC for backend deploys

This is a separate Terraform state from the infrastructure state. From
`envs/dev`, configure `bootstrap/github-oidc/oidc.auto.tfvars` with the correct
region and allowed GitHub subject, and review the backend bucket/key in
`bootstrap/github-oidc/main.tf`. Its default allowed subject is the `dev` branch
of `1uBank/cba-core`. If the AWS account already has the GitHub OIDC provider,
set `create_oidc_provider = false` in `oidc.auto.tfvars`.

```powershell
Set-Location ..\..\bootstrap\github-oidc
terraform init
terraform validate
terraform plan
terraform apply
terraform output -raw deploy_role_arn
```

Set the GitHub repository variables `AWS_REGION` and `AWS_ROLE_ARN` (the value
from the output). Add `DEV_BASE_URL` if the workflow uses a health check, and
copy `cba-core-repo/.github/workflows/deploy-dev.yml` into the backend
repository's `.github/workflows/` directory. The supplied OIDC policy covers
the **backend** ECR repository and service; it does not authorize pushing the
frontend image or updating the web ECS service.

### 7. Deploy and start the backend

The supplied backend GitHub Actions workflow builds and pushes the backend image
to the backend ECR repository, then registers a task definition revision. Run
the workflow after configuring OIDC and initializing the database.

After the backend image is deployed, start the backend service:

```powershell
aws ecs update-service --region $Region --cluster cba-core-dev --service cba-core-dev --desired-count 1
```

Wait for the service to become stable and verify the backend health endpoint:

```powershell
curl.exe https://<hostname-or-alb-dns>/fineract-provider/actuator/health/readiness
```

When a hostname is configured, use it in place of `<hostname-or-alb-dns>`.
Complete the application's first-login/admin-password setup before sharing the
environment.

## cba-auth and cba-banking-api (same cluster, same ALB)

Two more services run in the existing `cba-core-dev` cluster, defined in
`modules/cba-core/auth.tf` and `modules/cba-core/banking_api.tf`:

| Service | Reached at | Port | Health (ALB target group) | ECR repository |
|---|---|---|---|---|
| cba-auth (Keycloak) | Host `auth_hostname` | 8080 | `:9000/health/ready` | `cba-core-dev-auth-api` (+ `cba-core-dev-auth-realm-loader`) |
| cba-banking-api | Host `banking_api_hostname` | 8080 | `:9001/actuator/health/readiness` | `cba-core-dev-banking-api` |

- Both names need DNS (set `route53_zone_id` to have Terraform create the records) and
  must be covered by `acm_certificate_arn`; a wildcard certificate is simplest.
- The Banking API and the realm loader reach the auth service on its internal address,
  `http://cba-auth.cba-core-dev.internal:8080` (Cloud Map, see `terraform output auth_internal_url`).
- Both services start with a desired count of 0, like the backend.
- The `cba-core` ECS service, task definition and routing are unchanged.

First deployment, after `terraform apply`:

1. Run each one-off database task once (`terraform output auth_db_init_run_command`,
   `terraform output banking_api_db_init_run_command`) and check the log group
   `/ecs/cba-core-dev-db-init` for `auth db-init finished` and `banking-api db-init finished`.
2. Apply `bootstrap/github-oidc` (it now also creates one deploy role per repo) and set the
   GitHub variables in each repo from the outputs.
3. Run the `dev` workflow of each repo to push the first image and register a task definition
   revision, then scale up:
   `aws ecs update-service --cluster cba-core-dev --service cba-core-dev-auth --desired-count 1`
   and the same for `cba-core-dev-banking-api`.
4. Start the auth service first. The realm loader (run by the cba-auth workflow) signs in as
   `realm_loader_username` using `REALM_LOADER_PASSWORD` from the secret `cba-core-dev/auth`.
   On the first start that is the bootstrap `admin`. Create a named admin, delete the temporary
   one, and update the secret and `realm_loader_username`.
5. Read the client secrets in the admin console and put them in Secrets Manager, as the cba-auth
   README describes.

Admin console: with `auth_block_admin_console = false` (the default) `/admin` is reachable
through the ALB, which in dev is already limited by `alb_ingress_cidrs`. Set it to `true` for any
environment where the ALB is open more widely.

Banking API settings that are not in its README, such as the CBA-CORE client, go in
`banking_api_extra_environment`. If the events module publishes to SNS, pass the topic ARNs in
`banking_api_sns_topic_arns` so its task role can publish.

## Verify the deployment

From `envs/dev`, check the services and ALB:

```powershell
aws ecs describe-services --region us-east-1 --cluster cba-core-dev --services cba-core-dev cba-core-dev-web --query "services[].{name:serviceName,running:runningCount,desired:desiredCount,status:status}"
terraform output alb_dns_name
```

Then test both paths:

```powershell
curl.exe https://<hostname-or-alb-dns>/
curl.exe https://<hostname-or-alb-dns>/fineract-provider/actuator/health/readiness
```

The first request should return the frontend page; the second should return the
backend readiness response. If either fails, inspect the ECS service events,
CloudWatch log groups `/ecs/cba-core-dev-web` and `/ecs/cba-core-dev`, and the
ALB target group health.

## Ongoing changes and state safety

- Use the same `envs/dev` directory, backend, and state for every infrastructure
  change to this dev stack.
- Terraform intentionally ignores backend `task_definition` and `desired_count`
  changes because deployment and scaling are managed outside Terraform.
- Backend image releases are handled by the backend deployment workflow.
- Frontend image releases are pushed to the web ECR repository; update
  `web_image_tag` and apply Terraform when using a new tag.
- Keep state files and saved plans private. Do not commit `terraform.tfvars`,
  state, plans, credentials, or generated secrets.
- Before applying production changes, use separate backend state and production
  values. Review the module's defaults for database deletion protection,
  snapshots, Multi-AZ, deployment settings, ingress restrictions, and ECR tag
  immutability.
