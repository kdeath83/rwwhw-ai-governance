variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "ap-southeast-2"
}

variable "project_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "rwwhw-ai-governance"
}

variable "environment" {
  description = "Environment (dev, staging, production)"
  type        = string
  default     = "production"
}

variable "fallback_agent_name" {
  description = "Name of fallback agent for circuit breaker recovery"
  type        = string
  default     = "safe-agent-v1"
}

variable "retention_days" {
  description = "S3 Object Lock retention in days (7 years = 2555)"
  type        = number
  default     = 2555
}
