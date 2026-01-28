#===============================================================================
# CrowdStrike Falcon Sensor - Outputs
#===============================================================================

output "ecr_repository_url" {
  description = "ECR repository URL for Falcon sensor images"
  value       = var.create_ecr_repository ? aws_ecr_repository.falcon_sensor[0].repository_url : "${local.aws_account_id}.dkr.ecr.${local.aws_region}.amazonaws.com/${var.ecr_repository_name}"
}

output "ecr_repository_arn" {
  description = "ECR repository ARN"
  value       = var.create_ecr_repository ? aws_ecr_repository.falcon_sensor[0].arn : null
}

output "falcon_sensor_image" {
  description = "Full Falcon sensor image URI"
  value       = "${var.create_ecr_repository ? aws_ecr_repository.falcon_sensor[0].repository_url : "${local.aws_account_id}.dkr.ecr.${local.aws_region}.amazonaws.com/${var.ecr_repository_name}"}:${var.falcon_sensor_image_tag}"
}

output "aws_account_id" {
  description = "AWS Account ID"
  value       = local.aws_account_id
}

output "aws_region" {
  description = "AWS Region"
  value       = local.aws_region
}
