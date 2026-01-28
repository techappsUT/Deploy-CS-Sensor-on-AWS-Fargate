# CrowdStrike Falcon Sensor — Deployment Guide

Step-by-step guide for deploying CrowdStrike Falcon sensors to AWS EKS and ECS Fargate using this Terraform module.

## Table of Contents

1. [Before You Begin](#before-you-begin)
2. [Prepare CrowdStrike Credentials](#prepare-crowdstrike-credentials)
3. [Configure Remote State](#configure-remote-state)
4. [Deploy to EKS](#deploy-to-eks)
5. [Deploy to ECS Fargate](#deploy-to-ecs-fargate)
6. [Verify Deployment](#verify-deployment)
7. [Upgrade the Sensor](#upgrade-the-sensor)
8. [Rollback](#rollback)
9. [Tear Down](#tear-down)

---

## Before You Begin

### Required Tools

| Tool | Minimum Version | Purpose |
|------|----------------|---------|
| Terraform | 1.5.0 | Infrastructure provisioning |
| AWS CLI | 2.x | AWS authentication and ECR login |
| Docker | 20.x | Sensor image pull/push, task definition patching |
| kubectl | 1.24+ | EKS cluster access (EKS only) |
| Helm | 3.x | Chart deployment (EKS only) |

### Required AWS Permissions

The IAM principal running Terraform needs:

- **ECR**: `ecr:CreateRepository`, `ecr:GetAuthorizationToken`, `ecr:BatchGetImage`, `ecr:PutImage`, `ecr:BatchCheckLayerAvailability`, `ecr:GetDownloadUrlForLayer`, `ecr:PutLifecyclePolicy`
- **EKS** (if deploying to EKS): `eks:DescribeCluster`
- **ECS** (if deploying to ECS): `ecs:RegisterTaskDefinition`, `ecs:UpdateService`, `ecs:DescribeServices`
- **IAM**: `iam:PassRole` (for ECS task/execution roles)

### Required CrowdStrike API Scopes

- **Falcon Images Download**: Read
- **Sensor Download**: Read

---

## Prepare CrowdStrike Credentials

### Step 1: Create API Client

1. Log in to the Falcon console
2. Go to **Support and resources > Resources and tools > API clients and keys**
3. Click **Create API client** (or **Add new API client**)
4. Enter a name and description
5. Select scopes: **Falcon Images Download: Read**, **Sensor Download: Read**
6. Click **Create**
7. Copy the **Client ID** and **Secret**

### Step 2: Get your CID with Checksum

1. Go to **Host setup and management > Deploy > Sensor downloads**
2. Locate your Customer ID (CID) with checksum at the top of the page
3. Copy it — it should be in the format `XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX-XX`

### Step 3: Store Credentials Securely

**Option A: Environment variables** (simplest)

```bash
export TF_VAR_falcon_client_id="<your-client-id>"
export TF_VAR_falcon_client_secret="<your-client-secret>"
export TF_VAR_falcon_cid="<your-cid-with-checksum>"
```

**Option B: AWS Secrets Manager** (recommended for production)

```bash
aws secretsmanager create-secret \
  --name crowdstrike/falcon-api \
  --secret-string '{
    "client_id": "<your-client-id>",
    "client_secret": "<your-client-secret>",
    "cid": "<your-cid-with-checksum>"
  }'
```

Then reference in Terraform:

```hcl
data "aws_secretsmanager_secret_version" "falcon" {
  secret_id = "crowdstrike/falcon-api"
}

locals {
  creds = jsondecode(data.aws_secretsmanager_secret_version.falcon.secret_string)
}

module "falcon" {
  source               = "./terraform-falcon-sensor"
  falcon_client_id     = local.creds.client_id
  falcon_client_secret = local.creds.client_secret
  falcon_cid           = local.creds.cid
  # ...
}
```

**Never commit `terraform.tfvars` with credentials.** The `.gitignore` in this repo excludes `terraform.tfvars` and `*.auto.tfvars`.

---

## Configure Remote State

For production, use S3 backend with DynamoDB locking. Create the resources first:

```bash
# Create S3 bucket for state
aws s3api create-bucket \
  --bucket my-terraform-state \
  --region us-east-1

aws s3api put-bucket-versioning \
  --bucket my-terraform-state \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket my-terraform-state \
  --server-side-encryption-configuration '{
    "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "aws:kms"}}]
  }'

# Create DynamoDB table for locking
aws dynamodb create-table \
  --table-name terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

Then uncomment and configure the backend block in `main.tf`:

```hcl
terraform {
  backend "s3" {
    bucket         = "my-terraform-state"
    key            = "falcon-sensor/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-locks"
  }
}
```

---

## Deploy to EKS

### Step 1: Create `terraform.tfvars`

```hcl
# Required
falcon_client_id     = ""  # set via env var or secrets manager
falcon_client_secret = ""  # set via env var or secrets manager
falcon_cid           = ""  # set via env var or secrets manager
falcon_cloud         = "us-1"

# Deployment
deployment_type      = "eks"
eks_cluster_name     = "my-production-cluster"

# Production: pin to explicit versions
falcon_sensor_image_tag = "7.10.0-16303"
# helm_chart_version    = "1.30.0"  # uncomment and set

# ECR
create_ecr_repository    = true
ecr_repository_name      = "falcon-sensor/falcon-node-sensor"
ecr_image_tag_mutability = "IMMUTABLE"

# Sensor
node_sensor_backend = "bpf"
platform_architecture = "x86_64"

# Tags
tags = {
  Environment = "production"
  Team        = "security"
}
```

### Step 2: Initialize and Plan

```bash
terraform init
terraform plan -out=falcon.tfplan
```

Review the plan output. You should see:
- ECR repository creation
- `null_resource.pull_and_push_falcon_image` (image pull/push)
- EKS module resources (namespaces, secrets, Helm releases)

### Step 3: Apply

```bash
terraform apply falcon.tfplan
```

The deployment order is:
1. ECR repository created
2. Sensor image pulled from CrowdStrike registry and pushed to ECR
3. Kubernetes namespaces created (`falcon-system`, `falcon-kac`, `falcon-image-analyzer`)
4. ECR pull secret created
5. Falcon Sensor Helm release deployed (DaemonSet)
6. Falcon KAC Helm release deployed
7. Falcon Image Analyzer Helm release deployed

If any Helm release fails, `atomic = true` ensures automatic rollback.

### Step 4: Verify

```bash
# Check all pods are running
kubectl get pods -n falcon-system
kubectl get pods -n falcon-kac
kubectl get pods -n falcon-image-analyzer

# Check sensor logs
kubectl logs -n falcon-system -l app.kubernetes.io/name=falcon-sensor --tail=50

# Verify Helm releases
helm list -n falcon-system
helm list -n falcon-kac
helm list -n falcon-image-analyzer
```

---

## Deploy to ECS Fargate

### Step 1: Prepare Your Task Definition

You need an existing ECS task definition JSON file. The patching utility modifies it to inject the Falcon Container sensor.

Requirements per the CrowdStrike documentation:
- The task definition must be valid ECS JSON
- Remove these managed parameters if present: `requiresAttributes`, `status`, `revision`, `compatibilities`, `registeredAt`, `registeredBy`, `tags` (if empty), `taskDefinitionArn`
- Do not use `crowdstrike-falcon-init-container` as a container name in your application

### Step 2: Create `terraform.tfvars`

```hcl
# Required
falcon_client_id     = ""  # set via env var or secrets manager
falcon_client_secret = ""  # set via env var or secrets manager
falcon_cid           = ""  # set via env var or secrets manager
falcon_cloud         = "us-1"

# Deployment
deployment_type     = "ecs"

# Production: pin to explicit version
falcon_sensor_image_tag = "7.10.0-16303"

# ECR
create_ecr_repository    = true
ecr_repository_name      = "falcon-sensor/falcon-container"
ecr_image_tag_mutability = "IMMUTABLE"

# ECS
ecs_cluster_name                   = "my-production-cluster"
ecs_service_name                   = "my-service"        # optional: auto-update service
ecs_task_definition_file           = "task-definition.json"
ecs_patched_task_definition_output = "patched-task-definition.json"

# Tags
tags = {
  Environment = "production"
  Team        = "security"
}
```

### Step 3: Initialize and Plan

```bash
terraform init
terraform plan -out=falcon.tfplan
```

Review the plan. You should see:
- ECR repository creation
- `null_resource.pull_and_push_falcon_image` (image pull/push)
- `null_resource.patch_task_definition` (task definition patching)
- `aws_ecs_task_definition.falcon_protected` (registration)

### Step 4: Apply

```bash
terraform apply falcon.tfplan
```

The deployment order is:
1. ECR repository created
2. Sensor image pulled from CrowdStrike registry and pushed to ECR
3. Task definition patched using the CrowdStrike patching utility (`docker run`)
4. Patched task definition registered with ECS
5. (Optional) ECS service updated with new task definition

### What the Patching Utility Does

Per the CrowdStrike documentation, the patching utility modifies your task definition to:
- Inject `crowdstrike-falcon-init-container` (copies sensor binaries into shared volume)
- Add `SYS_PTRACE` capability to each container's `linuxParameters`
- Add `FALCONCTL_OPTS` environment variable with your CID (and sensor tags if configured)
- Add `dependsOn` for the init container
- Modify each container's `entryPoint` to start the Falcon sensor first
- Add `mountPoints` and `volumes` for the CrowdStrike shared volume

### Step 5: Verify

```bash
# Check task definition includes Falcon init container
aws ecs describe-task-definition \
  --task-definition <FAMILY:REVISION> \
  --query 'taskDefinition.containerDefinitions[*].name'
# Expected: ["app", "crowdstrike-falcon-init-container"]

# Run a task
aws ecs run-task \
  --cluster my-production-cluster \
  --task-definition <FAMILY:REVISION> \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-xxx],securityGroups=[sg-xxx]}" \
  --launch-type FARGATE

# Exec in and verify sensor (requires ECS Exec enabled)
aws ecs execute-command \
  --cluster my-production-cluster \
  --task <TASK_ID> \
  --container app \
  --command "ps -aef | grep falcon"

# Verify AID assignment
aws ecs execute-command \
  --cluster my-production-cluster \
  --task <TASK_ID> \
  --container app \
  --command "/tmp/CrowdStrike/rootfs/bin/falconctl -g --aid"
```

A valid AID in the output confirms the sensor is connected to the CrowdStrike cloud.

### Disabling Sensor for Specific Containers

To exclude a container from Falcon injection, add this label to its `dockerLabels`:

```json
"dockerLabels": {
  "sensor.falcon-system.crowdstrike.com/injection": "disabled"
}
```

---

## Verify Deployment

### Falcon Console Verification

1. Log in to the Falcon console
2. Go to **Host setup and management > Manage endpoints > Host management**
3. For EKS: filter by hostname or cluster name
4. For ECS Fargate: add a **Pod ID** filter and set it to the ECS Task ID
5. Verify the **Host ID** field has a value — this confirms the sensor has an AID

### Health Check Commands

**EKS:**
```bash
# All sensor pods should be Running
kubectl get pods -n falcon-system -o wide

# Sensor daemonset should match node count
kubectl get daemonset -n falcon-system
```

**ECS:**
```bash
# Check running tasks have 2 containers (app + falcon init)
aws ecs describe-tasks \
  --cluster my-cluster \
  --tasks <TASK_ID> \
  --query 'tasks[*].containers[*].name'
```

---

## Upgrade the Sensor

### Step 1: Update the Image Tag

In your `terraform.tfvars`:

```hcl
falcon_sensor_image_tag = "7.11.0-17000"  # new version
```

### Step 2: Re-pull the Image

The `null_resource.pull_and_push_falcon_image` triggers on `image_tag` changes, so a new tag automatically re-runs the pull/push.

```bash
terraform plan   # should show null_resource replacement
terraform apply
```

### Step 3: For EKS — Helm Releases Update Automatically

The sensor image reference in the Helm values changes, triggering a rolling update of the DaemonSet.

### Step 4: For ECS — Re-patch and Re-deploy

The patching utility re-runs with the new image, producing a new task definition revision. If `update_ecs_service` is enabled, the ECS service automatically picks up the new revision.

---

## Rollback

### EKS

Helm releases use `atomic = true`, so failed deployments auto-rollback. For manual rollback:

```bash
helm rollback falcon-sensor <REVISION> -n falcon-system
helm rollback falcon-kac <REVISION> -n falcon-kac
helm rollback falcon-image-analyzer <REVISION> -n falcon-image-analyzer
```

### ECS

Update the ECS service to a previous task definition revision:

```bash
aws ecs update-service \
  --cluster my-cluster \
  --service my-service \
  --task-definition <FAMILY>:<PREVIOUS_REVISION>
```

### Terraform State

To rollback the entire Terraform state:

```bash
# Revert tfvars to previous image tag
# Then re-apply
terraform apply
```

---

## Tear Down

### Remove Falcon from EKS

```bash
terraform destroy -target=module.eks
```

This removes the Helm releases and Kubernetes namespaces. Pods will terminate and sensor processes stop.

### Remove Falcon from ECS

```bash
terraform destroy -target=module.ecs_fargate
```

This deregisters the patched task definition. Existing running tasks continue until replaced.

### Full Teardown

```bash
terraform destroy
```

The ECR repository has `prevent_destroy = true`. To destroy it:

1. Edit `main.tf` and remove or comment out the `lifecycle { prevent_destroy = true }` block
2. Run `terraform destroy` again

### Post-Teardown

- Verify hosts are removed from the Falcon console at **Host setup and management > Manage endpoints > Host management**
- Decommission the API client in the Falcon console if no longer needed

---

## Appendix: Supported Cloud Regions

| `falcon_cloud` value | API Endpoint | Registry Endpoint |
|---------------------|-------------|-------------------|
| `us-1` (default) | `api.crowdstrike.com` | `registry.crowdstrike.com` |
| `us-2` | `api.us-2.crowdstrike.com` | `registry.crowdstrike.com` |
| `eu-1` | `api.eu-1.crowdstrike.com` | `registry.crowdstrike.com` |
| `us-gov-1` | `api.laggar.gcw.crowdstrike.com` | `registry.laggar.gcw.crowdstrike.com` |
| `us-gov-2` | `api.us-gov-2.crowdstrike.mil` | `registry.us-gov-2.crowdstrike.mil` |

## Appendix: File Structure

```
terraform-falcon-sensor/
├── main.tf                          # Root module: ECR, image pull/push, module calls
├── variables.tf                     # Root module variables
├── outputs.tf                       # Root module outputs
├── versions.tf                      # Provider version constraints
├── terraform.tfvars.example         # Example variable values
├── Makefile                         # Development targets
├── .gitignore                       # Ignores state, tfvars, .terraform/
├── .pre-commit-config.yaml          # Pre-commit hooks
├── tests/
│   └── root_module.tftest.hcl       # Variable validation tests
├── docs/
│   └── DEPLOYMENT.md                # This file
├── modules/
│   ├── eks/
│   │   ├── main.tf                  # Helm releases (sensor, KAC, IAR)
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── versions.tf
│   └── ecs-fargate/
│       ├── main.tf                  # Task definition patching
│       ├── variables.tf
│       ├── outputs.tf
│       └── versions.tf
└── examples/
    ├── eks-complete/
    │   └── main.tf                  # Full EKS example
    └── ecs-complete/
        └── main.tf                  # Full ECS Fargate example
```
