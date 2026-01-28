#===============================================================================
# CrowdStrike Falcon Sensor - EKS Module Variables
#===============================================================================

#-------------------------------------------------------------------------------
# CrowdStrike Configuration
#-------------------------------------------------------------------------------

variable "falcon_cid" {
  description = "CrowdStrike Customer ID (CID) with checksum"
  type        = string
  sensitive   = true
}

variable "falcon_cloud" {
  description = "CrowdStrike cloud region (us-1, us-2, eu-1, us-gov-1, us-gov-2)"
  type        = string
  default     = "us-1"

  validation {
    condition     = contains(["us-1", "us-2", "eu-1", "us-gov-1", "us-gov-2"], var.falcon_cloud)
    error_message = "Falcon cloud must be one of: us-1, us-2, eu-1, us-gov-1, us-gov-2."
  }
}

variable "falcon_client_id" {
  description = "CrowdStrike Falcon API Client ID (required for IAR)"
  type        = string
  sensitive   = true
}

variable "falcon_client_secret" {
  description = "CrowdStrike Falcon API Client Secret (required for IAR)"
  type        = string
  sensitive   = true
}

variable "cluster_name" {
  description = "Kubernetes cluster name (passed to KAC and IAR)"
  type        = string
}

variable "sensor_tags" {
  description = "Tags to apply to the Falcon sensor for grouping"
  type        = list(string)
  default     = []
}

#-------------------------------------------------------------------------------
# EKS Cluster Configuration
#-------------------------------------------------------------------------------

variable "eks_cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = ""
}

variable "eks_cluster_endpoint" {
  description = "EKS cluster endpoint (overrides auto-discovery)"
  type        = string
  default     = ""
}

variable "eks_cluster_ca_certificate" {
  description = "EKS cluster CA certificate base64 encoded (overrides auto-discovery)"
  type        = string
  default     = ""
}

#-------------------------------------------------------------------------------
# Namespace Configuration
#-------------------------------------------------------------------------------

variable "namespace" {
  description = "Kubernetes namespace for Falcon sensor"
  type        = string
  default     = "falcon-system"
}

variable "create_namespace" {
  description = "Create the Kubernetes namespace"
  type        = bool
  default     = true
}

variable "kac_namespace" {
  description = "Kubernetes namespace for Falcon KAC"
  type        = string
  default     = "falcon-kac"
}

variable "iar_namespace" {
  description = "Kubernetes namespace for Falcon Image Analyzer"
  type        = string
  default     = "falcon-image-analyzer"
}

#-------------------------------------------------------------------------------
# Helm Configuration
#-------------------------------------------------------------------------------

variable "helm_repository_url" {
  description = "Helm chart repository URL for CrowdStrike Falcon charts"
  type        = string
  default     = "https://crowdstrike.github.io/falcon-helm"
}

variable "release_name" {
  description = "Helm release name for Falcon sensor"
  type        = string
  default     = "falcon-sensor"
}

variable "enable_kac" {
  description = "Enable deployment of Falcon Kubernetes Admission Controller (KAC)"
  type        = bool
  default     = true
}

variable "enable_iar" {
  description = "Enable deployment of Falcon Image Analyzer (IAR)"
  type        = bool
  default     = true
}

variable "kac_release_name" {
  description = "Helm release name for Falcon KAC"
  type        = string
  default     = "falcon-kac"
}

variable "iar_release_name" {
  description = "Helm release name for Falcon Image Analyzer"
  type        = string
  default     = "falcon-image-analyzer"
}

variable "chart_version" {
  description = "Falcon sensor Helm chart version. WARNING: null (default) uses latest, which is non-deterministic and may cause unexpected upgrades. Pin to a specific version for production."
  type        = string
  default     = null
}

variable "kac_chart_version" {
  description = "Falcon KAC Helm chart version. WARNING: null (default) uses latest, which is non-deterministic and may cause unexpected upgrades. Pin to a specific version for production."
  type        = string
  default     = null
}

variable "iar_chart_version" {
  description = "Falcon Image Analyzer Helm chart version. WARNING: null (default) uses latest, which is non-deterministic and may cause unexpected upgrades. Pin to a specific version for production."
  type        = string
  default     = null
}

variable "helm_wait" {
  description = "Wait for Helm release to be deployed"
  type        = bool
  default     = true
}

variable "helm_wait_for_jobs" {
  description = "Wait for all Helm jobs to complete"
  type        = bool
  default     = true
}

variable "helm_timeout" {
  description = "Helm timeout in seconds"
  type        = number
  default     = 600
}

variable "additional_helm_values" {
  description = "Additional Helm values to merge with defaults"
  type        = any
  default     = {}
}

#-------------------------------------------------------------------------------
# Platform Architecture
#-------------------------------------------------------------------------------

variable "platform_architecture" {
  description = "Platform architecture for the Falcon sensor image (x86_64 or aarch64). When aarch64, nodeAffinity rules are automatically added to schedule pods on ARM64 nodes."
  type        = string
  default     = "x86_64"

  validation {
    condition     = contains(["x86_64", "aarch64"], var.platform_architecture)
    error_message = "Platform architecture must be either 'x86_64' or 'aarch64'."
  }
}

#-------------------------------------------------------------------------------
# Sensor Image Configuration
#-------------------------------------------------------------------------------

variable "sensor_image_repository" {
  description = "Falcon sensor image repository"
  type        = string
}

variable "sensor_image_tag" {
  description = "Falcon sensor image tag. Production recommendation: pin to an explicit version instead of 'latest' for deterministic deployments."
  type        = string
  default     = "latest"
}

variable "image_pull_policy" {
  description = "Image pull policy for the Falcon sensor. Supported values: Always, IfNotPresent."
  type        = string
  default     = "Always"

  validation {
    condition     = contains(["Always", "IfNotPresent"], var.image_pull_policy)
    error_message = "Image pull policy must be either 'Always' or 'IfNotPresent'."
  }
}

variable "create_ecr_pull_secret" {
  description = "Create ECR pull secret for private repository"
  type        = bool
  default     = true
}

#-------------------------------------------------------------------------------
# Sensor Configuration
#-------------------------------------------------------------------------------

variable "node_sensor_backend" {
  description = "Falcon node sensor backend: kernel or bpf"
  type        = string
  default     = "bpf"

  validation {
    condition     = contains(["kernel", "bpf"], var.node_sensor_backend)
    error_message = "Node sensor backend must be either 'kernel' or 'bpf'."
  }
}

variable "enable_container_sensor" {
  description = "Enable container sensor (sidecar injection)"
  type        = bool
  default     = false
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
# Pod Security Admission
#-------------------------------------------------------------------------------

variable "psa_enforce_level" {
  description = "Pod Security Admission enforce level for Falcon namespaces"
  type        = string
  default     = "privileged"

  validation {
    condition     = contains(["privileged", "baseline", "restricted"], var.psa_enforce_level)
    error_message = "PSA enforce level must be one of: privileged, baseline, restricted."
  }
}
