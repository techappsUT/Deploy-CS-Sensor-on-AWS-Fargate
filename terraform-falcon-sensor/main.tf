#===============================================================================
# CrowdStrike Falcon Sensor Terraform Module
# Supports: ECS Fargate (Sidecar) and EKS (Helm DaemonSet)
#
# Reference: CrowdStrike Falcon Container Sensor for Linux documentation
# https://falcon.crowdstrike.com/documentation/page/a5c297cc/deploy-falcon-container-sensor-for-linux-on-ecs-fargate
#===============================================================================

#===============================================================================
# Data Sources
#===============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_ecr_authorization_token" "token" {}

#===============================================================================
# Local Variables
#===============================================================================

locals {
  aws_account_id = data.aws_caller_identity.current.account_id
  aws_region     = data.aws_region.current.id

  # CrowdStrike API endpoints per cloud region
  # See: https://falcon.crowdstrike.com/documentation/page/a5c297cc/deploy-falcon-container-sensor-for-linux-on-ecs-fargate
  falcon_api_url      = var.falcon_api_endpoints[var.falcon_cloud]
  falcon_registry_url = var.falcon_registry_endpoints[var.falcon_cloud]

  ecr_repository_url = "${local.aws_account_id}.dkr.ecr.${local.aws_region}.amazonaws.com/${var.ecr_repository_name}"

  common_tags = merge(var.tags, var.default_tags)
}

#===============================================================================
# ECR Repository for Falcon Sensor Images
#===============================================================================

resource "aws_ecr_repository" "falcon_sensor" {
  count = var.create_ecr_repository ? 1 : 0

  name                 = var.ecr_repository_name
  image_tag_mutability = var.ecr_image_tag_mutability

  image_scanning_configuration {
    scan_on_push = var.ecr_scan_on_push
  }

  encryption_configuration {
    encryption_type = var.ecr_encryption_type
    kms_key         = var.ecr_kms_key_arn
  }

  tags = local.common_tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_ecr_lifecycle_policy" "falcon_sensor" {
  count = var.create_ecr_repository && var.ecr_lifecycle_policy_enabled ? 1 : 0

  repository = aws_ecr_repository.falcon_sensor[0].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last ${var.ecr_image_retention_count} images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.ecr_image_retention_count
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

#===============================================================================
# Pull and Push Falcon Sensor Image
# Uses the CrowdStrike falcon-container-sensor-pull.sh script to retrieve
# the latest sensor image and push it to ECR.
# Reference: https://falcon.crowdstrike.com/documentation/page/a5c297cc/deploy-falcon-container-sensor-for-linux-on-ecs-fargate
# Note: The --platform flag supports x86_64 or aarch64 per CrowdStrike docs.
#===============================================================================

resource "null_resource" "pull_and_push_falcon_image" {
  count = var.enable_image_push ? 1 : 0

  triggers = {
    image_tag = var.falcon_sensor_image_tag
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      FALCON_CLIENT_ID     = var.falcon_client_id
      FALCON_CLIENT_SECRET = var.falcon_client_secret
      FALCON_CLOUD         = var.falcon_cloud
      AWS_REGION           = local.aws_region
      ECR_REPO             = var.create_ecr_repository ? aws_ecr_repository.falcon_sensor[0].repository_url : "${local.aws_account_id}.dkr.ecr.${local.aws_region}.amazonaws.com/${var.ecr_repository_name}"
      SENSOR_TYPE          = var.deployment_type == "eks" ? "falcon-sensor" : "falcon-container"
      IMAGE_TAG            = var.falcon_sensor_image_tag
      PLATFORM             = var.platform_architecture
      PULL_SCRIPT_URL      = var.falcon_pull_script_url
    }

    command = <<-EOT
      set -euo pipefail

      timeout 600 bash -c '
        echo "Pulling Falcon sensor image..."

        # Pull using CrowdStrike script
        # See: https://falcon.crowdstrike.com/documentation/page/a5c297cc/deploy-falcon-container-sensor-for-linux-on-ecs-fargate
        LATEST_SENSOR=$(bash <(curl -sL "$PULL_SCRIPT_URL") \
          -t $SENSOR_TYPE \
          --platform $PLATFORM \
          2>&1 | tail -1)

        echo "Pulled image: $LATEST_SENSOR"

        # Login to ECR
        aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REPO

        # Tag and push
        docker tag "$LATEST_SENSOR" "$ECR_REPO:$IMAGE_TAG"
        docker push "$ECR_REPO:$IMAGE_TAG"

        echo "Pushed to: $ECR_REPO:$IMAGE_TAG"
      '
    EOT
  }

  depends_on = [aws_ecr_repository.falcon_sensor]
}

#===============================================================================
# EKS Module
#===============================================================================

module "eks" {
  source = "./modules/eks"
  count  = contains(["eks", "both"], var.deployment_type) ? 1 : 0

  # CrowdStrike Configuration
  falcon_cid           = var.falcon_cid
  falcon_cloud         = var.falcon_cloud
  falcon_client_id     = var.falcon_client_id
  falcon_client_secret = var.falcon_client_secret
  cluster_name         = var.eks_cluster_name
  sensor_tags          = var.sensor_tags

  # EKS Configuration
  eks_cluster_name           = var.eks_cluster_name
  eks_cluster_endpoint       = var.eks_cluster_endpoint
  eks_cluster_ca_certificate = var.eks_cluster_ca_certificate

  # Helm Configuration
  release_name  = var.helm_release_name
  chart_version = var.helm_chart_version

  # Sensor Image Configuration
  sensor_image_repository = var.create_ecr_repository ? aws_ecr_repository.falcon_sensor[0].repository_url : local.ecr_repository_url
  sensor_image_tag        = var.falcon_sensor_image_tag
  platform_architecture   = var.platform_architecture

  # Namespace Configuration
  namespace        = var.helm_namespace
  create_namespace = var.helm_create_namespace

  # Sensor Configuration
  node_sensor_backend   = var.node_sensor_backend
  node_sensor_resources = var.node_sensor_resources

  # Additional Helm values
  additional_helm_values = var.helm_values

  depends_on = [null_resource.pull_and_push_falcon_image]
}

#===============================================================================
# ECS Fargate Module
#===============================================================================

module "ecs_fargate" {
  source = "./modules/ecs-fargate"
  count  = contains(["ecs", "both"], var.deployment_type) ? 1 : 0

  # CrowdStrike Configuration
  falcon_cid  = var.falcon_cid
  sensor_tags = var.sensor_tags

  # Sensor Image Configuration
  sensor_image_repository = var.create_ecr_repository ? aws_ecr_repository.falcon_sensor[0].repository_url : local.ecr_repository_url
  sensor_image_tag        = var.falcon_sensor_image_tag

  # Task Definition Configuration
  task_definition_file           = var.ecs_task_definition_file
  patched_task_definition_output = var.ecs_patched_task_definition_output

  # ECS Service Configuration
  ecs_cluster_name = var.ecs_cluster_name
  ecs_service_name = var.ecs_service_name

  tags = local.common_tags

  depends_on = [null_resource.pull_and_push_falcon_image]
}
