#===============================================================================
# CrowdStrike Falcon Sensor - ECS Fargate Module
# Patches ECS Task Definitions with Falcon Container Sensor
#
# Reference: https://falcon.crowdstrike.com/documentation/page/a5c297cc/deploy-falcon-container-sensor-for-linux-on-ecs-fargate
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

  ecr_registry = "${local.aws_account_id}.dkr.ecr.${local.aws_region}.amazonaws.com"
  sensor_image = "${var.sensor_image_repository}:${var.sensor_image_tag}"

  # Generate pull token for ECR
  ecr_pull_token = base64encode(jsonencode({
    auths = {
      "${local.ecr_registry}" = {
        auth = base64encode("AWS:${data.aws_ecr_authorization_token.token.password}")
      }
    }
  }))

  # Build FALCONCTL_OPTS (CID is passed separately via -cid flag)
  falconctl_opts = length(var.sensor_tags) > 0 ? "--tags='${join(",", var.sensor_tags)}'" : ""

  # Determine output file path
  output_file = var.patched_task_definition_output != "" ? var.patched_task_definition_output : "${path.module}/patched-task-definition.json"
}

#===============================================================================
# Read Original Task Definition
#===============================================================================

data "local_file" "original_task_definition" {
  count    = var.task_definition_file != "" ? 1 : 0
  filename = var.task_definition_file
}

#===============================================================================
# Patch Task Definition using CrowdStrike Patching Utility
# Reference: https://falcon.crowdstrike.com/documentation/page/a5c297cc/deploy-falcon-container-sensor-for-linux-on-ecs-fargate#xf9f70ed
#===============================================================================

resource "null_resource" "patch_task_definition" {
  count = var.task_definition_file != "" ? 1 : 0

  triggers = {
    task_definition_hash = filemd5(var.task_definition_file)
    sensor_image         = local.sensor_image
    falcon_cid           = var.falcon_cid
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      AWS_REGION     = local.aws_region
      ECR_REGISTRY   = local.ecr_registry
      SENSOR_IMAGE   = local.sensor_image
      FALCON_CID     = var.falcon_cid
      PULL_TOKEN     = local.ecr_pull_token
      TASK_DEF_FILE  = var.task_definition_file
      OUTPUT_FILE    = local.output_file
      FALCONCTL_OPTS = local.falconctl_opts
    }

    command = <<-EOT
      set -euo pipefail

      timeout 300 bash -c '
        # Login to ECR
        aws ecr get-login-password --region $AWS_REGION | \
          docker login --username AWS --password-stdin $ECR_REGISTRY

        # Get the directory and filename
        TASK_DEF_DIR=$(dirname "$TASK_DEF_FILE")
        TASK_DEF_BASENAME=$(basename "$TASK_DEF_FILE")

        # Run the patching utility
        FALCONCTL_ARGS=""
        if [ -n "$FALCONCTL_OPTS" ]; then
          FALCONCTL_ARGS="--falconctl-opts $FALCONCTL_OPTS"
        fi

        docker run -v "$TASK_DEF_DIR:/var/run/spec" \
          --rm "$SENSOR_IMAGE" \
          -cid "$FALCON_CID" \
          -image "$SENSOR_IMAGE" \
          -pulltoken "$PULL_TOKEN" \
          $FALCONCTL_ARGS \
          -ecs-spec-file "/var/run/spec/$TASK_DEF_BASENAME" > "$OUTPUT_FILE"

        echo "Patched task definition saved to: $OUTPUT_FILE"
      '
    EOT
  }
}

#===============================================================================
# Read Patched Task Definition
#===============================================================================

data "local_file" "patched_task_definition" {
  count      = var.task_definition_file != "" ? 1 : 0
  filename   = local.output_file
  depends_on = [null_resource.patch_task_definition]
}

#===============================================================================
# Register Patched Task Definition
#===============================================================================

resource "aws_ecs_task_definition" "falcon_protected" {
  count = var.task_definition_file != "" && var.register_task_definition ? 1 : 0

  family                   = var.task_family != "" ? var.task_family : jsondecode(data.local_file.patched_task_definition[0].content).family
  container_definitions    = jsonencode(jsondecode(data.local_file.patched_task_definition[0].content).containerDefinitions)
  task_role_arn            = var.task_role_arn
  execution_role_arn       = var.execution_role_arn
  network_mode             = var.network_mode
  requires_compatibilities = var.requires_compatibilities
  cpu                      = var.task_cpu
  memory                   = var.task_memory

  dynamic "volume" {
    for_each = try(jsondecode(data.local_file.patched_task_definition[0].content).volumes, [])
    content {
      name = volume.value.name
    }
  }

  tags = var.tags

  depends_on = [null_resource.patch_task_definition]
}

#===============================================================================
# Update ECS Service (Optional)
#===============================================================================

resource "aws_ecs_service" "falcon_protected" {
  count = var.update_ecs_service && var.ecs_cluster_name != "" && var.ecs_service_name != "" ? 1 : 0

  name            = var.ecs_service_name
  cluster         = var.ecs_cluster_name
  task_definition = aws_ecs_task_definition.falcon_protected[0].arn
  desired_count   = var.service_desired_count

  deployment_maximum_percent         = var.deployment_maximum_percent
  deployment_minimum_healthy_percent = var.deployment_minimum_healthy_percent

  force_new_deployment = true

  network_configuration {
    subnets          = var.service_subnets
    security_groups  = var.service_security_groups
    assign_public_ip = var.assign_public_ip
  }

  dynamic "load_balancer" {
    for_each = var.load_balancer_config != null ? [var.load_balancer_config] : []
    content {
      target_group_arn = load_balancer.value.target_group_arn
      container_name   = load_balancer.value.container_name
      container_port   = load_balancer.value.container_port
    }
  }

  tags = var.tags

  lifecycle {
    ignore_changes = [desired_count]
  }
}
