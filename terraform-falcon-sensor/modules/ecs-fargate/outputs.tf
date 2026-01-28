#===============================================================================
# CrowdStrike Falcon Sensor - ECS Fargate Module Outputs
#===============================================================================

output "patched_task_definition_file" {
  description = "Path to the patched task definition file"
  value       = local.output_file
}

output "task_definition_arn" {
  description = "ARN of the registered task definition"
  value       = var.register_task_definition && length(aws_ecs_task_definition.falcon_protected) > 0 ? aws_ecs_task_definition.falcon_protected[0].arn : null
}

output "task_definition_revision" {
  description = "Revision number of the registered task definition"
  value       = var.register_task_definition && length(aws_ecs_task_definition.falcon_protected) > 0 ? aws_ecs_task_definition.falcon_protected[0].revision : null
}

output "ecs_service_id" {
  description = "ID of the updated ECS service"
  value       = var.update_ecs_service && length(aws_ecs_service.falcon_protected) > 0 ? aws_ecs_service.falcon_protected[0].id : null
}

output "sensor_image" {
  description = "Falcon sensor image used"
  value       = local.sensor_image
}
