#===============================================================================
# Complete ECS Fargate Deployment Example
# Deploys CrowdStrike Falcon Container Sensor to ECS Fargate Tasks
#===============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0"
    }
  }

  # Uncomment to use remote state with locking
  # backend "s3" {
  #   bucket         = "your-terraform-state-bucket"
  #   key            = "falcon-sensor/ecs/terraform.tfstate"
  #   region         = "us-east-1"
  #   encrypt        = true
  #   dynamodb_table = "terraform-locks"
  # }
}

#===============================================================================
# Provider Configuration
#===============================================================================

provider "aws" {
  region = var.aws_region
}

#===============================================================================
# Variables
#===============================================================================

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "falcon_client_id" {
  description = "CrowdStrike Falcon API Client ID"
  type        = string
  sensitive   = true
}

variable "falcon_client_secret" {
  description = "CrowdStrike Falcon API Client Secret"
  type        = string
  sensitive   = true
}

variable "falcon_cid" {
  description = "CrowdStrike Customer ID with checksum"
  type        = string
  sensitive   = true
}

variable "falcon_cloud" {
  description = "CrowdStrike cloud region"
  type        = string
  default     = "us-1"
}

variable "sensor_tags" {
  description = "Tags for sensor grouping in Falcon console"
  type        = list(string)
  default     = []
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "production"
}

# ECS Configuration
variable "ecs_cluster_name" {
  description = "Name of the ECS cluster"
  type        = string
}

variable "ecs_service_name" {
  description = "Name of the ECS service to update"
  type        = string
  default     = ""
}

variable "vpc_id" {
  description = "VPC ID for ECS service"
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs for ECS service"
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security group IDs for ECS service"
  type        = list(string)
  default     = []
}

#===============================================================================
# Data Sources
#===============================================================================

data "aws_caller_identity" "current" {}

#===============================================================================
# Local Variables
#===============================================================================

locals {
  aws_account_id = data.aws_caller_identity.current.account_id

  common_tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Application = "CrowdStrike-Falcon"
  }
}

#===============================================================================
# IAM Roles for ECS
#===============================================================================

resource "aws_iam_role" "ecs_execution_role" {
  name = "falcon-ecs-execution-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ecs_execution_role_policy" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Allow pulling from ECR
resource "aws_iam_role_policy" "ecs_execution_ecr" {
  name = "ecr-pull"
  role = aws_iam_role.ecs_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAuth"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
        Sid    = "ECRPull"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = "arn:aws:ecr:*:*:repository/falcon-sensor/*"
      }
    ]
  })
}

resource "aws_iam_role" "ecs_task_role" {
  name = "falcon-ecs-task-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

#===============================================================================
# CloudWatch Log Group
#===============================================================================

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/falcon-protected-app-${var.environment}"
  retention_in_days = 30

  tags = local.common_tags
}

#===============================================================================
# Sample Application Task Definition (to be patched)
#===============================================================================

resource "local_file" "sample_task_definition" {
  filename = "${path.module}/sample-task-definition.json"
  content = jsonencode({
    family                  = "falcon-protected-app"
    networkMode             = "awsvpc"
    requiresCompatibilities = ["FARGATE"]
    cpu                     = "256"
    memory                  = "512"
    executionRoleArn        = aws_iam_role.ecs_execution_role.arn
    taskRoleArn             = aws_iam_role.ecs_task_role.arn
    containerDefinitions = [
      {
        name      = "app"
        image     = "nginx:latest"
        essential = true
        portMappings = [
          {
            containerPort = 80
            protocol      = "tcp"
          }
        ]
        logConfiguration = {
          logDriver = "awslogs"
          options = {
            "awslogs-group"         = aws_cloudwatch_log_group.app.name
            "awslogs-region"        = var.aws_region
            "awslogs-stream-prefix" = "app"
          }
        }
      }
    ]
  })
}

#===============================================================================
# Deploy CrowdStrike Falcon via Root Module
#===============================================================================

module "falcon" {
  source = "../../"

  # CrowdStrike Configuration
  falcon_client_id     = var.falcon_client_id
  falcon_client_secret = var.falcon_client_secret
  falcon_cid           = var.falcon_cid
  falcon_cloud         = var.falcon_cloud
  sensor_tags          = var.sensor_tags

  # Deployment Configuration
  deployment_type = "ecs"

  # ECR Configuration
  create_ecr_repository = true
  ecr_repository_name   = "falcon-sensor/falcon-container"

  # ECS Configuration
  ecs_cluster_name                   = var.ecs_cluster_name
  ecs_service_name                   = var.ecs_service_name
  ecs_task_definition_file           = local_file.sample_task_definition.filename
  ecs_patched_task_definition_output = "${path.module}/patched-task-definition.json"

  # Tags
  tags = local.common_tags

  depends_on = [local_file.sample_task_definition]
}

#===============================================================================
# Security Group for ECS Tasks (if not provided)
#===============================================================================

resource "aws_security_group" "ecs_tasks" {
  count = length(var.security_group_ids) == 0 ? 1 : 0

  name        = "falcon-ecs-tasks-${var.environment}"
  description = "Security group for Falcon-protected ECS tasks"
  vpc_id      = var.vpc_id

  # WARNING: 0.0.0.0/0 is for demo purposes only. In production, restrict
  # this to specific CIDR ranges or use a load balancer with proper ACLs.
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "falcon-ecs-tasks-${var.environment}"
  })
}

#===============================================================================
# Outputs
#===============================================================================

output "ecr_repository_url" {
  description = "ECR repository URL for Falcon container sensor"
  value       = module.falcon.ecr_repository_url
}

output "falcon_sensor_image" {
  description = "Full Falcon sensor image URI"
  value       = module.falcon.falcon_sensor_image
}

output "deployment_instructions" {
  description = "Post-deployment instructions"
  value       = <<-EOT

    Falcon Container Sensor deployed to ECS!

    To run a task manually:
      aws ecs run-task \
        --cluster ${var.ecs_cluster_name} \
        --network-configuration "awsvpcConfiguration={subnets=[${join(",", var.subnet_ids)}],securityGroups=[${length(var.security_group_ids) > 0 ? join(",", var.security_group_ids) : aws_security_group.ecs_tasks[0].id}]}" \
        --launch-type FARGATE

    To verify sensor is running:
      aws ecs execute-command \
        --cluster ${var.ecs_cluster_name} \
        --task <TASK_ID> \
        --container app \
        --command "ps -aef | grep falcon"

    Verify in Falcon console:
      https://falcon.crowdstrike.com/hosts/hosts

  EOT
}
