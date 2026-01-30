#===============================================================================
# CrowdStrike Falcon Sensor - Variables
#
# Reference: CrowdStrike Falcon Container Sensor for Linux documentation
# https://falcon.crowdstrike.com/documentation/page/a5c297cc/deploy-falcon-container-sensor-for-linux-on-ecs-fargate
#===============================================================================

#-------------------------------------------------------------------------------
# AWS Configuration
#-------------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region for provider configuration"
  type        = string
  default     = "us-east-1"
}

#-------------------------------------------------------------------------------
# CrowdStrike Configuration
#-------------------------------------------------------------------------------

variable "falcon_client_id" {
  description = "CrowdStrike Falcon API Client ID. Required API scopes: Falcon Images Download (Read), Sensor Download (Read). See: https://falcon.crowdstrike.com/documentation/page/a5c297cc/deploy-falcon-container-sensor-for-linux-on-ecs-fargate#ba83eb6c"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.falcon_client_id) >= 20
    error_message = "Falcon Client ID must be at least 20 characters."
  }
}

variable "falcon_client_secret" {
  description = "CrowdStrike Falcon API Client Secret. See: https://falcon.crowdstrike.com/documentation/page/a5c297cc/deploy-falcon-container-sensor-for-linux-on-ecs-fargate#ba83eb6c"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.falcon_client_secret) >= 20
    error_message = "Falcon Client Secret must be at least 20 characters."
  }
}

variable "falcon_cid" {
  description = "CrowdStrike Customer ID (CID) with checksum. Found at: Falcon Console > Host setup and management > Deploy > Sensor downloads. See: https://falcon.crowdstrike.com/documentation/page/a5c297cc/deploy-falcon-container-sensor-for-linux-on-ecs-fargate#qfa6ddd0"
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[A-Za-z0-9]+-[A-Za-z0-9]+$", var.falcon_cid))
    error_message = "Falcon CID must be in format: XXXXXXXX-XX (with checksum)."
  }
}

variable "falcon_cloud" {
  description = "CrowdStrike cloud region. Determines API and registry endpoints used for sensor retrieval. See: https://falcon.crowdstrike.com/documentation/page/a5c297cc/deploy-falcon-container-sensor-for-linux-on-ecs-fargate"
  type        = string
  default     = "us-1"

  validation {
    condition     = contains(["us-1", "us-2", "eu-1", "us-gov-1", "us-gov-2"], var.falcon_cloud)
    error_message = "Falcon cloud must be one of: us-1, us-2, eu-1, us-gov-1, us-gov-2."
  }
}

variable "falcon_sensor_image_tag" {
  description = "Tag for the Falcon sensor image in ECR. Production recommendation: pin to an explicit version instead of 'latest' for deterministic deployments."
  type        = string
  default     = "latest"
}

variable "sensor_tags" {
  description = "Tags to apply to the Falcon sensor for grouping in Falcon console. Passed via --falconctl-opts '--tags'. See: https://falcon.crowdstrike.com/documentation/page/dde40c99/configuration-options-for-falcon-container-sensor#wc4ab0be"
  type        = list(string)
  default     = []
}

#-------------------------------------------------------------------------------
# CrowdStrike API & Registry Endpoints
# Reference: https://falcon.crowdstrike.com/documentation/page/a5c297cc/deploy-falcon-container-sensor-for-linux-on-ecs-fargate
#-------------------------------------------------------------------------------

variable "falcon_api_endpoints" {
  description = "Map of CrowdStrike cloud region to API endpoint. Override to add custom or new regions."
  type        = map(string)
  default = {
    "us-1"     = "api.crowdstrike.com"
    "us-2"     = "api.us-2.crowdstrike.com"
    "eu-1"     = "api.eu-1.crowdstrike.com"
    "us-gov-1" = "api.laggar.gcw.crowdstrike.com"
    "us-gov-2" = "api.us-gov-2.crowdstrike.mil"
  }
}

variable "falcon_registry_endpoints" {
  description = "Map of CrowdStrike cloud region to container registry endpoint. Override to add custom or new regions."
  type        = map(string)
  default = {
    "us-1"     = "registry.crowdstrike.com"
    "us-2"     = "registry.crowdstrike.com"
    "eu-1"     = "registry.crowdstrike.com"
    "us-gov-1" = "registry.laggar.gcw.crowdstrike.com"
    "us-gov-2" = "registry.us-gov-2.crowdstrike.mil"
  }
}

#-------------------------------------------------------------------------------
# Sensor Image Pull Configuration
# Reference: https://falcon.crowdstrike.com/documentation/page/a5c297cc/deploy-falcon-container-sensor-for-linux-on-ecs-fargate#r242f9bb
#-------------------------------------------------------------------------------

variable "platform_architecture" {
  description = "Platform architecture for the Falcon sensor image. The multi-arch image cannot be copied locally; specify x86_64 or aarch64. See: https://falcon.crowdstrike.com/documentation/page/a5c297cc/deploy-falcon-container-sensor-for-linux-on-ecs-fargate#r242f9bb"
  type        = string
  default     = "x86_64"

  validation {
    condition     = contains(["x86_64", "aarch64"], var.platform_architecture)
    error_message = "Platform architecture must be either 'x86_64' or 'aarch64'."
  }
}

variable "falcon_pull_script_url" {
  description = "URL for the CrowdStrike falcon-container-sensor-pull.sh script. See: https://falcon.crowdstrike.com/documentation/page/a5c297cc/deploy-falcon-container-sensor-for-linux-on-ecs-fargate#r242f9bb"
  type        = string
  default     = "https://github.com/CrowdStrike/falcon-scripts/releases/latest/download/falcon-container-sensor-pull.sh"
}

#-------------------------------------------------------------------------------
# Deployment Configuration
#-------------------------------------------------------------------------------

variable "deployment_type" {
  description = "Type of deployment: 'ecs', 'eks', or 'both'"
  type        = string
  default     = "eks"

  validation {
    condition     = contains(["ecs", "eks", "both"], var.deployment_type)
    error_message = "Deployment type must be one of: ecs, eks, both."
  }
}

variable "enable_image_push" {
  description = "Enable automatic pull and push of Falcon sensor image to ECR"
  type        = bool
  default     = true
}

#-------------------------------------------------------------------------------
# ECR Configuration
#-------------------------------------------------------------------------------

variable "create_ecr_repository" {
  description = "Create a new ECR repository for Falcon sensor images"
  type        = bool
  default     = true
}

variable "ecr_repository_name" {
  description = "Name of the ECR repository for Falcon sensor images"
  type        = string
  default     = "falcon-sensor/falcon-container"
}

variable "ecr_image_tag_mutability" {
  description = "ECR image tag mutability setting: MUTABLE or IMMUTABLE"
  type        = string
  default     = "IMMUTABLE"

  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE"], var.ecr_image_tag_mutability)
    error_message = "ECR image tag mutability must be either 'MUTABLE' or 'IMMUTABLE'."
  }
}

variable "ecr_scan_on_push" {
  description = "Enable image scanning on push"
  type        = bool
  default     = true
}

variable "ecr_encryption_type" {
  description = "ECR encryption type: AES256 or KMS"
  type        = string
  default     = "AES256"
}

variable "ecr_kms_key_arn" {
  description = "KMS key ARN for ECR encryption (required if ecr_encryption_type is KMS)"
  type        = string
  default     = null
}

variable "ecr_lifecycle_policy_enabled" {
  description = "Enable ECR lifecycle policy"
  type        = bool
  default     = true
}

variable "ecr_image_retention_count" {
  description = "Number of images to retain in ECR"
  type        = number
  default     = 10
}

#-------------------------------------------------------------------------------
# EKS Configuration
#-------------------------------------------------------------------------------

variable "eks_cluster_name" {
  description = "Name of the EKS cluster (required for EKS deployment)"
  type        = string
  default     = ""
}

variable "eks_cluster_endpoint" {
  description = "EKS cluster endpoint URL"
  type        = string
  default     = ""
}

variable "eks_cluster_ca_certificate" {
  description = "EKS cluster CA certificate (base64 encoded)"
  type        = string
  default     = ""
}

variable "helm_release_name" {
  description = "Helm release name for Falcon sensor"
  type        = string
  default     = "falcon-sensor"
}

variable "helm_namespace" {
  description = "Kubernetes namespace for Falcon sensor"
  type        = string
  default     = "falcon-system"
}

variable "helm_create_namespace" {
  description = "Create the Kubernetes namespace if it doesn't exist"
  type        = bool
  default     = true
}

variable "helm_chart_version" {
  description = "Version of the falcon-sensor Helm chart"
  type        = string
  default     = null # Uses latest if not specified
}

variable "helm_values" {
  description = "Additional Helm values to pass to the chart"
  type        = any
  default     = {}
}

variable "node_sensor_backend" {
  description = "Falcon node sensor backend: kernel or bpf"
  type        = string
  default     = "bpf"

  validation {
    condition     = contains(["kernel", "bpf"], var.node_sensor_backend)
    error_message = "Node sensor backend must be either 'kernel' or 'bpf'."
  }
}

variable "node_sensor_resources" {
  description = "Resource limits and requests for node sensor pods"
  type = object({
    limits = object({
      cpu    = string
      memory = string
    })
    requests = object({
      cpu    = string
      memory = string
    })
  })
  default = {
    limits = {
      cpu    = "750m"
      memory = "256Mi"
    }
    requests = {
      cpu    = "500m"
      memory = "256Mi"
    }
  }
}

#-------------------------------------------------------------------------------
# ECS Configuration
#-------------------------------------------------------------------------------

variable "ecs_cluster_name" {
  description = "Name of the ECS cluster (for service updates)"
  type        = string
  default     = ""
}

variable "ecs_service_name" {
  description = "Name of the ECS service to update"
  type        = string
  default     = ""
}

variable "ecs_task_definition_file" {
  description = "Path to the ECS task definition JSON file to patch. See: https://falcon.crowdstrike.com/documentation/page/a5c297cc/deploy-falcon-container-sensor-for-linux-on-ecs-fargate#xf9f70ed"
  type        = string
  default     = ""
}

variable "ecs_patched_task_definition_output" {
  description = "Output path for the patched ECS task definition"
  type        = string
  default     = "patched-task-definition.json"
}

#-------------------------------------------------------------------------------
# Tags
#-------------------------------------------------------------------------------

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "default_tags" {
  description = "Default tags applied to all resources. Merged with var.tags."
  type        = map(string)
  default = {
    "ManagedBy"   = "Terraform"
    "Application" = "CrowdStrike-Falcon"
  }
}
