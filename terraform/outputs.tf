output "evidence_bucket" {
  description = "S3 bucket for WWHW evidence (7-year retention)"
  value       = aws_s3_bucket.wwhw_evidence.id
}

output "agent_registry_table" {
  description = "DynamoDB table for agent ownership (Who)"
  value       = aws_dynamodb_table.agent_registry.name
}

output "session_memory_table" {
  description = "DynamoDB table for session traces (What)"
  value       = aws_dynamodb_table.session_memory.name
}

output "circuit_breaker_lambda" {
  description = "Lambda function for automatic stopping (How)"
  value       = aws_lambda_function.circuit_breaker.function_name
}

output "human_review_workflow" {
  description = "Step Functions workflow for human approval (How)"
  value       = aws_sfn_state_machine.human_review.name
}

output "evidence_generator_lambda" {
  description = "Lambda for evidence package generation (What Evidence)"
  value       = aws_lambda_function.evidence_generator.function_name
}

output "dashboard_url" {
  description = "CloudWatch Dashboard URL for 30-second incident response"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.wwhw.dashboard_name}"
}

output "incident_alert_topic" {
  description = "SNS topic for incident alerts"
  value       = aws_sns_topic.incident_alerts.arn
}
