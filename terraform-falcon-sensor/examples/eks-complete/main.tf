#===============================================================================
# Complete EKS Deployment Example
# Deploys CrowdStrike Falcon Sensor, KAC, and Image Analyzer to EKS
#===============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.17"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.35"
    }
  }

  # Uncomment to use remote state with locking
  # backend "s3" {
  #   bucket         = "your-terraform-state-bucket"
  #   key            = "falcon-sensor/eks/terraform.tfstate"
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

# Get EKS cluster details
data "aws_eks_cluster" "cluster" {
  name = var.eks_cluster_name
}

data "aws_eks_cluster_auth" "cluster" {
  name = var.eks_cluster_name
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.cluster.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}

#===============================================================================
# Variables
#===============================================================================

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "eks_cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
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
  description = "Environment name (e.g., production, staging)"
  type        = string
  default     = "production"
}

variable "sensor_image_tag" {
  description = "Falcon sensor image tag in ECR"
  type        = string
  default     = "latest"
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
  deployment_type         = "eks"
  falcon_sensor_image_tag = var.sensor_image_tag

  # ECR Configuration
  create_ecr_repository = true
  ecr_repository_name   = "falcon-sensor/falcon-node-sensor"

  # EKS Configuration
  eks_cluster_name  = var.eks_cluster_name
  helm_release_name = "falcon-sensor"
  helm_namespace    = "falcon-system"

  # Sensor Configuration
  node_sensor_backend = "bpf"
  node_sensor_resources = {
    limits = {
      cpu    = "750m"
      memory = "256Mi"
    }
    requests = {
      cpu    = "500m"
      memory = "256Mi"
    }
  }

  # Additional Helm values
  helm_values = {
    node = {
      daemonset = {
        annotations = {
          "cluster-autoscaler.kubernetes.io/safe-to-evict" = "false"
        }
      }
    }
  }

  # Tags
  tags = {
    Environment = var.environment
  }
}

#===============================================================================
# Outputs
#===============================================================================

output "ecr_repository_url" {
  description = "ECR repository URL for Falcon sensor"
  value       = module.falcon.ecr_repository_url
}

output "falcon_sensor_image" {
  description = "Full Falcon sensor image URI"
  value       = module.falcon.falcon_sensor_image
}

output "deployment_instructions" {
  description = "Post-deployment instructions"
  value       = <<-EOT

    Falcon Platform deployed to EKS cluster: ${var.eks_cluster_name}

    Verify deployments:
      kubectl get pods -n falcon-system
      kubectl get pods -n falcon-kac
      kubectl get pods -n falcon-image-analyzer

    Check sensor logs:
      kubectl logs -n falcon-system -l app=falcon-sensor

    Verify in Falcon console:
      https://falcon.crowdstrike.com/hosts/hosts

  EOT
}
