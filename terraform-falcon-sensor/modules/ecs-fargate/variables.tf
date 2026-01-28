#===============================================================================
# CrowdStrike Falcon Sensor - ECS Fargate Module Variables
#
# Reference: https://falcon.crowdstrike.com/documentation/page/a5c297cc/deploy-falcon-container-sensor-for-linux-on-ecs-fargate
#===============================================================================

#-------------------------------------------------------------------------------
# CrowdStrike Configuration
#-------------------------------------------------------------------------------

variable "falcon_cid" {
  description = "CrowdStrike Customer ID (CID) with checksum"
  type        = string
  sensitive   = true
}

variable "sensor_tags" {
  description = "Tags to apply to the Falcon sensor for grouping"
  type        = list(string)
  default     = []
}

#-------------------------------------------------------------------------------
# Sensor Image Configuration
#-------------------------------------------------------------------------------

variable "sensor_image_repository" {
  description = "Falcon container sensor image repository"
  type        = string
}

variable "sensor_image_tag" {
  description = "Falcon container sensor image tag. Production recommendation: pin to an explicit version instead of 'latest' for deterministic deployments."
  type        = string
  default     = "latest"
}

#-------------------------------------------------------------------------------
# Task Definition Configuration
#-------------------------------------------------------------------------------

variable "task_definition_file" {
  description = "Path to the original ECS task definition JSON file. See: https://falcon.crowdstrike.com/documentation/page/a5c297cc/deploy-falcon-container-sensor-for-linux-on-ecs-fargate#xf9f70ed"
  type        = string
}

variable "patched_task_definition_output" {
  description = "Output path for the patched task definition"
  type        = string
  default     = ""
}

variable "register_task_definition" {
  description = "Register the patched task definition with ECS"
  type        = bool
  default     = true
}

variable "task_family" {
  description = "Task definition family name (defaults to original)"
  type        = string
  default     = ""
}

variable "task_role_arn" {
  description = "IAM role ARN for the task"
  type        = string
  default     = null
}

variable "execution_role_arn" {
  description = "IAM role ARN for task execution"
  type        = string
  default     = null
}

variable "task_cpu" {
  description = "CPU units for the task (256, 512, 1024, 2048, 4096)"
  type        = string
  default     = "256"
}

variable "task_memory" {
  description = "Memory for the task in MB"
  type        = string
  default     = "512"
}

variable "network_mode" {
  description = "Docker networking mode for the task. See: https://falcon.crowdstrike.com/documentation/page/a5c297cc/deploy-falcon-container-sensor-for-linux-on-ecs-fargate"
  type        = string
  default     = "awsvpc"
}

variable "requires_compatibilities" {
  description = "Launch type required by the task. See: https://falcon.crowdstrike.com/documentation/page/a5c297cc/deploy-falcon-container-sensor-for-linux-on-ecs-fargate"
  type        = list(string)
  default     = ["FARGATE"]
}

#-------------------------------------------------------------------------------
# ECS Service Configuration
#-------------------------------------------------------------------------------

variable "update_ecs_service" {
  description = "Update an existing ECS service with the new task definition"
  type        = bool
  default     = false
}

variable "ecs_cluster_name" {
  description = "Name of the ECS cluster"
  type        = string
  default     = ""
}

variable "ecs_service_name" {
  description = "Name of the ECS service to update"
  type        = string
  default     = ""
}

variable "service_desired_count" {
  description = "Desired number of tasks"
  type        = number
  default     = 1
}

variable "deployment_maximum_percent" {
  description = "Maximum percent of tasks during deployment"
  type        = number
  default     = 200
}

variable "deployment_minimum_healthy_percent" {
  description = "Minimum healthy percent during deployment"
  type        = number
  default     = 100
}

variable "service_subnets" {
  description = "Subnets for the ECS service"
  type        = list(string)
  default     = []
}

variable "service_security_groups" {
  description = "Security groups for the ECS service"
  type        = list(string)
  default     = []
}

variable "assign_public_ip" {
  description = "Assign public IP to tasks"
  type        = bool
  default     = false
}

variable "load_balancer_config" {
  description = "Load balancer configuration"
  type = object({
    target_group_arn = string
    container_name   = string
    container_port   = number
  })
  default = null
}

#-------------------------------------------------------------------------------
# Tags
#-------------------------------------------------------------------------------

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
