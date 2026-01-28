#===============================================================================
# CrowdStrike Falcon Sensor - EKS Module
# Deploys Falcon Sensor, KAC, and Image Analyzer via Helm
#
# Note: Kubernetes and Helm providers must be configured in the root module
# and passed to this module. Do not define provider blocks here.
#===============================================================================

#===============================================================================
# Data Sources
#===============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Get EKS cluster details if cluster name provided
data "aws_eks_cluster" "cluster" {
  count = var.eks_cluster_name != "" ? 1 : 0
  name  = var.eks_cluster_name
}

data "aws_eks_cluster_auth" "cluster" {
  count = var.eks_cluster_name != "" ? 1 : 0
  name  = var.eks_cluster_name
}

#===============================================================================
# Local Variables
#===============================================================================

locals {
  aws_account_id = data.aws_caller_identity.current.account_id
  aws_region     = data.aws_region.current.id

  cluster_endpoint       = var.eks_cluster_endpoint != "" ? var.eks_cluster_endpoint : try(data.aws_eks_cluster.cluster[0].endpoint, "")
  cluster_ca_certificate = var.eks_cluster_ca_certificate != "" ? var.eks_cluster_ca_certificate : try(data.aws_eks_cluster.cluster[0].certificate_authority[0].data, "")
  cluster_token          = try(data.aws_eks_cluster_auth.cluster[0].token, "")

  sensor_image = "${var.sensor_image_repository}:${var.sensor_image_tag}"

  # Build sensor tags for FALCONCTL_OPTS
  sensor_tags_string = length(var.sensor_tags) > 0 ? join(",", var.sensor_tags) : ""

  # PSA labels for privileged workloads
  psa_labels = {
    "pod-security.kubernetes.io/enforce" = var.psa_enforce_level
    "pod-security.kubernetes.io/audit"   = var.psa_enforce_level
    "pod-security.kubernetes.io/warn"    = var.psa_enforce_level
  }

  # Default Helm values
  default_helm_values = {
    falcon = {
      cid   = var.falcon_cid
      cloud = var.falcon_cloud
      tags  = join(",", var.sensor_tags)
    }

    node = {
      enabled = true
      backend = var.node_sensor_backend

      image = {
        repository = var.sensor_image_repository
        tag        = var.sensor_image_tag
        pullPolicy = var.image_pull_policy
      }

      daemonset = {
        tolerations = [
          {
            operator = "Exists"
            effect   = "NoSchedule"
          },
          {
            operator = "Exists"
            effect   = "NoExecute"
          }
        ]
      }

      resources = var.node_sensor_resources
    }

    container = {
      enabled = var.enable_container_sensor
    }
  }

  # Merge with user-provided values
  helm_values = merge(local.default_helm_values, var.additional_helm_values)
}

#===============================================================================
# Kubernetes Namespaces
#===============================================================================

resource "kubernetes_namespace_v1" "falcon_system" {
  count = var.create_namespace ? 1 : 0

  metadata {
    name = var.namespace

    labels = merge(
      {
        "name"                         = var.namespace
        "app.kubernetes.io/managed-by" = "terraform"
        "app.kubernetes.io/part-of"    = "crowdstrike-falcon"
      },
      local.psa_labels,
    )
  }
}

resource "kubernetes_namespace_v1" "falcon_kac" {
  count = var.create_namespace ? 1 : 0

  metadata {
    name = var.kac_namespace

    labels = merge(
      {
        "name"                         = var.kac_namespace
        "app.kubernetes.io/managed-by" = "terraform"
        "app.kubernetes.io/part-of"    = "crowdstrike-falcon"
      },
      local.psa_labels,
    )
  }
}

resource "kubernetes_namespace_v1" "falcon_iar" {
  count = var.create_namespace ? 1 : 0

  metadata {
    name = var.iar_namespace

    labels = merge(
      {
        "name"                         = var.iar_namespace
        "app.kubernetes.io/managed-by" = "terraform"
        "app.kubernetes.io/part-of"    = "crowdstrike-falcon"
      },
      local.psa_labels,
    )
  }
}

#===============================================================================
# ECR Pull Secret (for private ECR repository)
#===============================================================================

resource "kubernetes_secret_v1" "ecr_pull_secret" {
  count = var.create_ecr_pull_secret ? 1 : 0

  metadata {
    name      = "falcon-ecr-pull-secret"
    namespace = var.create_namespace ? kubernetes_namespace_v1.falcon_system[0].metadata[0].name : var.namespace
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "${local.aws_account_id}.dkr.ecr.${local.aws_region}.amazonaws.com" = {
          auth = base64encode("AWS:${data.aws_ecr_authorization_token.token.password}")
        }
      }
    })
  }

  depends_on = [kubernetes_namespace_v1.falcon_system]
}

data "aws_ecr_authorization_token" "token" {}

#===============================================================================
# Helm Release - Falcon Sensor
#===============================================================================

resource "helm_release" "falcon_sensor" {
  name             = var.release_name
  repository       = var.helm_repository_url
  chart            = "falcon-sensor"
  version          = var.chart_version
  namespace        = var.create_namespace ? kubernetes_namespace_v1.falcon_system[0].metadata[0].name : var.namespace
  create_namespace = false

  atomic        = true
  wait          = var.helm_wait
  wait_for_jobs = var.helm_wait_for_jobs
  timeout       = var.helm_timeout

  values = [yamlencode(merge(local.helm_values, var.create_ecr_pull_secret ? {
    imagePullSecrets = [{
      name = kubernetes_secret_v1.ecr_pull_secret[0].metadata[0].name
    }]
  } : {}))]

  depends_on = [
    kubernetes_namespace_v1.falcon_system,
    kubernetes_secret_v1.ecr_pull_secret
  ]
}

#===============================================================================
# Helm Release - Falcon KAC
#===============================================================================

resource "helm_release" "falcon_kac" {
  name             = var.kac_release_name
  repository       = var.helm_repository_url
  chart            = "falcon-kac"
  version          = var.kac_chart_version
  namespace        = var.create_namespace ? kubernetes_namespace_v1.falcon_kac[0].metadata[0].name : var.kac_namespace
  create_namespace = false

  atomic        = true
  wait          = var.helm_wait
  wait_for_jobs = var.helm_wait_for_jobs
  timeout       = var.helm_timeout

  values = [yamlencode({
    falcon = {
      cid   = var.falcon_cid
      cloud = var.falcon_cloud
    }
    clusterName = var.cluster_name
  })]

  depends_on = [
    kubernetes_namespace_v1.falcon_kac,
    helm_release.falcon_sensor,
  ]
}

#===============================================================================
# Helm Release - Falcon Image Analyzer
#===============================================================================

resource "helm_release" "falcon_image_analyzer" {
  name             = var.iar_release_name
  repository       = var.helm_repository_url
  chart            = "falcon-image-analyzer"
  version          = var.iar_chart_version
  namespace        = var.create_namespace ? kubernetes_namespace_v1.falcon_iar[0].metadata[0].name : var.iar_namespace
  create_namespace = false

  atomic        = true
  wait          = var.helm_wait
  wait_for_jobs = var.helm_wait_for_jobs
  timeout       = var.helm_timeout

  values = [yamlencode({
    falcon = {
      cid   = var.falcon_cid
      cloud = var.falcon_cloud
    }
    deployment = {
      enabled = true
    }
    crowdstrikeConfig = {
      clusterName  = var.cluster_name
      clientID     = var.falcon_client_id
      clientSecret = var.falcon_client_secret
    }
  })]

  depends_on = [
    kubernetes_namespace_v1.falcon_iar,
    helm_release.falcon_kac,
  ]
}
