#===============================================================================
# CrowdStrike Falcon Sensor - EKS Module Outputs
#===============================================================================

output "namespace" {
  description = "Kubernetes namespace where Falcon sensor is deployed"
  value       = var.create_namespace ? kubernetes_namespace_v1.falcon_system[0].metadata[0].name : var.namespace
}

output "helm_release_name" {
  description = "Helm release name for Falcon sensor"
  value       = helm_release.falcon_sensor.name
}

output "helm_release_status" {
  description = "Helm release status for Falcon sensor"
  value       = helm_release.falcon_sensor.status
}

output "helm_release_version" {
  description = "Helm chart version deployed for Falcon sensor"
  value       = helm_release.falcon_sensor.version
}

output "sensor_image" {
  description = "Falcon sensor image deployed"
  value       = local.sensor_image
}

output "kac_release_name" {
  description = "Helm release name for Falcon KAC"
  value       = var.enable_kac ? helm_release.falcon_kac[0].name : null
}

output "kac_release_status" {
  description = "Helm release status for Falcon KAC"
  value       = var.enable_kac ? helm_release.falcon_kac[0].status : null
}

output "iar_release_name" {
  description = "Helm release name for Falcon Image Analyzer"
  value       = var.enable_iar ? helm_release.falcon_image_analyzer[0].name : null
}

output "iar_release_status" {
  description = "Helm release status for Falcon Image Analyzer"
  value       = var.enable_iar ? helm_release.falcon_image_analyzer[0].status : null
}
