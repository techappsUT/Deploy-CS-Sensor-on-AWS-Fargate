# CrowdStrike Falcon Sensor Terraform Module

Terraform module for deploying CrowdStrike Falcon sensors to AWS ECS Fargate and EKS clusters.

Reference: [Deploy Falcon Container Sensor for Linux on ECS Fargate](https://falcon.crowdstrike.com/documentation/page/a5c297cc/deploy-falcon-container-sensor-for-linux-on-ecs-fargate)

## Features

- **EKS Deployment**: Falcon Node Sensor (DaemonSet), KAC, and Image Analyzer via Helm
- **ECS Fargate Deployment**: Task definition patching with Falcon Container Sensor
- **ECR Integration**: Automatic sensor image pull and push to private ECR
- **Atomic Helm Releases**: Failed deployments auto-rollback
- **Dependency Ordering**: Sensor → KAC → Image Analyzer deployed sequentially
- **Immutable Tags**: ECR defaults to `IMMUTABLE` to prevent tag overwriting
- **ECR Protection**: `prevent_destroy` lifecycle on ECR repository
- **Timeouts**: `local-exec` provisioners wrapped with timeouts to prevent hangs

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Terraform Deployment                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐      │
│  │  CrowdStrike │    │     ECR      │    │   EKS/ECS    │      │
│  │   Registry   │───▶│  Repository  │───▶│   Cluster    │      │
│  └──────────────┘    └──────────────┘    └──────────────┘      │
│         │                   │                   │               │
│         ▼                   ▼                   ▼               │
│  ┌──────────────────────────────────────────────────────┐      │
│  │              Falcon Sensor Deployment                 │      │
│  │  • EKS: Helm charts (DaemonSet + KAC + IAR)          │      │
│  │  • ECS: Patched Task Definition (Sidecar)            │      │
│  └──────────────────────────────────────────────────────┘      │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## Prerequisites

### Tools Required

- Terraform >= 1.5.0
- AWS CLI configured with appropriate permissions
- Docker (for image pull/push and task definition patching)
- kubectl (for EKS deployments)
- Helm 3.x (for EKS deployments)

### CrowdStrike API Credentials

Create API credentials in the Falcon console at **Support and resources > Resources and tools > API clients and keys** with these scopes:

- **Falcon Images Download**: Read
- **Sensor Download**: Read

### CrowdStrike CID

Retrieve your CID with checksum from **Host setup and management > Deploy > Sensor downloads**.

## Quick Start

### EKS Deployment

```bash
cd examples/eks-complete

cat > terraform.tfvars << 'EOF'
falcon_client_id     = "your-client-id"
falcon_client_secret = "your-secret"
falcon_cid           = "YOUR-CID-WITH-CHECKSUM"
falcon_cloud         = "us-1"
eks_cluster_name     = "my-cluster"
aws_region           = "us-east-1"
EOF

terraform init
terraform plan
terraform apply
```

### ECS Fargate Deployment

```bash
cd examples/ecs-complete

cat > terraform.tfvars << 'EOF'
falcon_client_id     = "your-client-id"
falcon_client_secret = "your-secret"
falcon_cid           = "YOUR-CID-WITH-CHECKSUM"
falcon_cloud         = "us-1"
ecs_cluster_name     = "my-cluster"
vpc_id               = "vpc-xxxxxxxx"
subnet_ids           = ["subnet-xxx", "subnet-yyy"]
aws_region           = "us-east-1"
EOF

terraform init
terraform plan
terraform apply
```

## Module Usage

### Root Module

```hcl
module "falcon" {
  source = "path/to/terraform-falcon-sensor"

  # CrowdStrike Configuration
  falcon_client_id     = var.falcon_client_id
  falcon_client_secret = var.falcon_client_secret
  falcon_cid           = var.falcon_cid
  falcon_cloud         = "us-1"
  sensor_tags          = ["production", "web-tier"]

  # Deployment type: "eks", "ecs", or "both"
  deployment_type = "eks"

  # ECR Configuration
  create_ecr_repository    = true
  ecr_repository_name      = "falcon-sensor/falcon-container"
  ecr_image_tag_mutability = "IMMUTABLE"  # default

  # Sensor image tag — pin to a specific version for production
  falcon_sensor_image_tag = "latest"

  # EKS Configuration (when deployment_type is "eks" or "both")
  eks_cluster_name  = "my-cluster"
  helm_release_name = "falcon-sensor"
  helm_namespace    = "falcon-system"
  helm_chart_version = "1.0.0"  # pin for production
  node_sensor_backend = "bpf"

  # ECS Configuration (when deployment_type is "ecs" or "both")
  ecs_cluster_name          = "my-cluster"
  ecs_task_definition_file  = "task-definition.json"

  tags = {
    Environment = "production"
  }
}
```

### EKS Module (Direct)

```hcl
module "falcon_sensor_eks" {
  source = "path/to/modules/eks"

  falcon_cid           = var.falcon_cid
  falcon_cloud         = "us-1"
  falcon_client_id     = var.falcon_client_id
  falcon_client_secret = var.falcon_client_secret
  cluster_name         = "my-cluster"
  sensor_tags          = ["production", "web-tier"]

  eks_cluster_name = "my-cluster"

  namespace        = "falcon-system"
  create_namespace = true

  release_name  = "falcon-sensor"
  chart_version = "1.0.0"  # pin for production

  sensor_image_repository = "123456789.dkr.ecr.us-east-1.amazonaws.com/falcon-sensor"
  sensor_image_tag        = "7.10.0-1234"

  node_sensor_backend = "bpf"
  node_sensor_resources = {
    limits   = { cpu = "750m", memory = "256Mi" }
    requests = { cpu = "500m", memory = "256Mi" }
  }
}
```

### ECS Fargate Module (Direct)

```hcl
module "falcon_sensor_ecs" {
  source = "path/to/modules/ecs-fargate"

  falcon_cid  = var.falcon_cid
  sensor_tags = ["production", "api"]

  sensor_image_repository = "123456789.dkr.ecr.us-east-1.amazonaws.com/falcon-container"
  sensor_image_tag        = "7.10.0-1234"

  task_definition_file     = "my-task-definition.json"
  register_task_definition = true
  task_family              = "my-app-protected"
  task_cpu                 = "512"
  task_memory              = "1024"

  update_ecs_service = true
  ecs_cluster_name   = "my-cluster"
  ecs_service_name   = "my-service"
  service_subnets    = ["subnet-xxx", "subnet-yyy"]
}
```

## Variables Reference

### Root Module Variables

| Variable | Description | Type | Default | Required |
|----------|-------------|------|---------|----------|
| `falcon_client_id` | CrowdStrike API Client ID | `string` | - | yes |
| `falcon_client_secret` | CrowdStrike API Client Secret | `string` | - | yes |
| `falcon_cid` | CrowdStrike CID with checksum | `string` | - | yes |
| `falcon_cloud` | CrowdStrike cloud region | `string` | `"us-1"` | no |
| `falcon_sensor_image_tag` | Sensor image tag in ECR | `string` | `"latest"` | no |
| `sensor_tags` | Tags for Falcon console grouping | `list(string)` | `[]` | no |
| `deployment_type` | `"eks"`, `"ecs"`, or `"both"` | `string` | `"eks"` | no |
| `enable_image_push` | Auto pull/push sensor image to ECR | `bool` | `true` | no |
| `create_ecr_repository` | Create ECR repository | `bool` | `true` | no |
| `ecr_repository_name` | ECR repository name | `string` | `"falcon-sensor/falcon-container"` | no |
| `ecr_image_tag_mutability` | `"MUTABLE"` or `"IMMUTABLE"` | `string` | `"IMMUTABLE"` | no |
| `platform_architecture` | `"x86_64"` or `"aarch64"` | `string` | `"x86_64"` | no |

### EKS Variables

| Variable | Description | Type | Default |
|----------|-------------|------|---------|
| `eks_cluster_name` | EKS cluster name | `string` | `""` |
| `helm_release_name` | Helm release name | `string` | `"falcon-sensor"` |
| `helm_namespace` | Kubernetes namespace | `string` | `"falcon-system"` |
| `helm_chart_version` | Helm chart version (null = latest) | `string` | `null` |
| `node_sensor_backend` | Sensor backend: `"kernel"` or `"bpf"` | `string` | `"bpf"` |

### ECS Variables

| Variable | Description | Type | Default |
|----------|-------------|------|---------|
| `ecs_cluster_name` | ECS cluster name | `string` | `""` |
| `ecs_service_name` | ECS service to update | `string` | `""` |
| `ecs_task_definition_file` | Path to task definition JSON | `string` | `""` |
| `ecs_patched_task_definition_output` | Output path for patched JSON | `string` | `"patched-task-definition.json"` |

## Outputs

### Root Module

| Output | Description |
|--------|-------------|
| `ecr_repository_url` | ECR repository URL |
| `ecr_repository_arn` | ECR repository ARN |
| `falcon_sensor_image` | Full sensor image URI |

### EKS Module

| Output | Description |
|--------|-------------|
| `namespace` | Kubernetes namespace |
| `helm_release_name` | Falcon sensor Helm release name |
| `helm_release_status` | Falcon sensor Helm release status |
| `helm_release_version` | Helm chart version deployed |
| `sensor_image` | Deployed sensor image |
| `kac_release_name` | KAC Helm release name |
| `kac_release_status` | KAC Helm release status |
| `iar_release_name` | Image Analyzer Helm release name |
| `iar_release_status` | Image Analyzer Helm release status |

### ECS Module

| Output | Description |
|--------|-------------|
| `patched_task_definition_file` | Path to patched JSON file |
| `task_definition_arn` | Registered task definition ARN |
| `task_definition_revision` | Task definition revision number |
| `ecs_service_id` | Updated ECS service ID |
| `sensor_image` | Falcon sensor image used |

## Supported CrowdStrike Cloud Regions

| Region | API Endpoint | Registry Endpoint |
|--------|-------------|-------------------|
| `us-1` | `api.crowdstrike.com` | `registry.crowdstrike.com` |
| `us-2` | `api.us-2.crowdstrike.com` | `registry.crowdstrike.com` |
| `eu-1` | `api.eu-1.crowdstrike.com` | `registry.crowdstrike.com` |
| `us-gov-1` | `api.laggar.gcw.crowdstrike.com` | `registry.laggar.gcw.crowdstrike.com` |
| `us-gov-2` | `api.us-gov-2.crowdstrike.mil` | `registry.us-gov-2.crowdstrike.mil` |

## Production Recommendations

- **Pin image tags**: Set `falcon_sensor_image_tag` to an explicit version instead of `"latest"`
- **Pin Helm chart versions**: Set `helm_chart_version`, `kac_chart_version`, `iar_chart_version` to specific versions
- **Use IMMUTABLE ECR tags**: The default (`"IMMUTABLE"`) prevents tag overwriting
- **Use remote state with locking**: See backend examples in `examples/*/main.tf`
- **Store secrets securely**: Use AWS Secrets Manager, HashiCorp Vault, or environment variables — never commit `terraform.tfvars` with credentials
- **Run pre-commit hooks**: Install `pre-commit` and use the provided `.pre-commit-config.yaml`

## Sensitive Data Handling

### Using Environment Variables

```bash
export TF_VAR_falcon_client_id="your-client-id"
export TF_VAR_falcon_client_secret="your-secret"
export TF_VAR_falcon_cid="YOUR-CID-WITH-CHECKSUM"

terraform apply
```

### Using AWS Secrets Manager

```hcl
data "aws_secretsmanager_secret_version" "falcon_credentials" {
  secret_id = "crowdstrike/falcon-api"
}

locals {
  falcon_creds = jsondecode(data.aws_secretsmanager_secret_version.falcon_credentials.secret_string)
}

module "falcon" {
  source = "./terraform-falcon-sensor"

  falcon_client_id     = local.falcon_creds.client_id
  falcon_client_secret = local.falcon_creds.client_secret
  falcon_cid           = local.falcon_creds.cid
  # ...
}
```

## Development

### Makefile Targets

```bash
make init       # terraform init
make validate   # terraform validate
make fmt        # terraform fmt -recursive
make lint       # fmt + validate
make plan       # terraform plan
make apply      # terraform apply
make destroy    # terraform destroy
```

### Pre-commit Hooks

```bash
pip install pre-commit
pre-commit install
pre-commit run --all-files
```

Hooks: `terraform_fmt`, `terraform_validate`, `terraform_tflint`, `terraform_tfsec`

### Tests

```bash
terraform test
```

Tests validate variable validation rules (client ID length, client secret length, CID format, deployment type, tag mutability).

## Troubleshooting

### Image Pull Failures

```bash
# Verify ECR repository exists
aws ecr describe-repositories --repository-names falcon-sensor/falcon-container

# Check image exists
aws ecr describe-images --repository-name falcon-sensor/falcon-container

# Manually test pull
aws ecr get-login-password | docker login --username AWS --password-stdin <ECR_URI>
docker pull <ECR_URI>:latest
```

### EKS Deployment Issues

```bash
# Check Helm releases
helm list -n falcon-system
helm list -n falcon-kac
helm list -n falcon-image-analyzer

# Check pods
kubectl get pods -n falcon-system
kubectl get pods -n falcon-kac
kubectl get pods -n falcon-image-analyzer

# Check sensor logs
kubectl logs -n falcon-system -l app=falcon-sensor
```

### ECS Task Definition Issues

```bash
# Describe task definition
aws ecs describe-task-definition --task-definition <TASK_DEF_ARN>

# Verify Falcon init container is present
aws ecs describe-task-definition --task-definition <TASK_DEF_ARN> \
  --query 'taskDefinition.containerDefinitions[*].name'

# Verify SYS_PTRACE capability
aws ecs describe-task-definition --task-definition <TASK_DEF_ARN> \
  --query 'taskDefinition.containerDefinitions[*].linuxParameters'
```

### ECS Sensor Verification

```bash
# Exec into container (requires ECS Exec enabled)
aws ecs execute-command \
  --cluster <CLUSTER_NAME> \
  --task <TASK_ID> \
  --container app \
  --command "ps -aef | grep falcon"

# Verify AID assignment
aws ecs execute-command \
  --cluster <CLUSTER_NAME> \
  --task <TASK_ID> \
  --container app \
  --command "/tmp/CrowdStrike/rootfs/bin/falconctl -g --aid"
```

## Cleanup

```bash
# Destroy all resources
terraform destroy

# Note: ECR repository has prevent_destroy enabled.
# To destroy it, first remove the lifecycle block from main.tf,
# then run terraform destroy.
```

## References

- [CrowdStrike Falcon Documentation](https://falcon.crowdstrike.com/documentation)
- [Deploy Falcon Container Sensor for Linux on ECS Fargate](https://falcon.crowdstrike.com/documentation/page/a5c297cc/deploy-falcon-container-sensor-for-linux-on-ecs-fargate)
- [Falconctl Configuration Options](https://falcon.crowdstrike.com/documentation/page/dde40c99/configuration-options-for-falcon-container-sensor)
- [CrowdStrike Falcon Helm Charts](https://github.com/CrowdStrike/falcon-helm)
- [CrowdStrike Container Security](https://github.com/CrowdStrike/Container-Security)
- [falcon-container-sensor-pull.sh](https://github.com/CrowdStrike/falcon-scripts/blob/main/bash/containers/falcon-container-sensor-pull/falcon-container-sensor-pull.sh)
- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest)
- [Terraform Helm Provider](https://registry.terraform.io/providers/hashicorp/helm/latest)
