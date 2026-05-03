terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.5.0"
}

provider "aws" {
  region = var.aws_region
}

# Random suffix for unique bucket names
resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
}

# S3 Bucket for RWWHW Evidence (7-year retention)
resource "aws_s3_bucket" "rwwhw_evidence" {
  bucket = "${var.project_name}-evidence-${random_string.suffix.result}"
}

resource "aws_s3_bucket_versioning" "rwwhw_evidence" {
  bucket = aws_s3_bucket.rwwhw_evidence.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "rwwhw_evidence" {
  bucket = aws_s3_bucket.rwwhw_evidence.id
  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = 2555  # 7 years
    }
  }
}

# DynamoDB for Agent Registry (Who)
resource "aws_dynamodb_table" "agent_registry" {
  name         = "${var.project_name}-agent-registry"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "agent_id"

  attribute {
    name = "agent_id"
    type = "S"
  }

  attribute {
    name = "risk_classification"
    type = "S"
  }

  global_secondary_index {
    name            = "RiskClassificationIndex"
    hash_key        = "risk_classification"
    projection_type = "ALL"
  }

  tags = {
    RWWHW      = "Who"
    Framework = "Governance"
  }
}

# DynamoDB for Session Memory (What)
resource "aws_dynamodb_table" "session_memory" {
  name         = "${var.project_name}-session-memory"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "session_id"
  range_key    = "timestamp"

  attribute {
    name = "session_id"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "S"
  }

  attribute {
    name = "agent_id"
    type = "S"
  }

  global_secondary_index {
    name            = "AgentIdIndex"
    hash_key        = "agent_id"
    range_key       = "timestamp"
    projection_type = "ALL"
  }

  tags = {
    RWWHW      = "What"
    Framework = "Governance"
  }
}

# CloudWatch Log Group for AgentCore
resource "aws_cloudwatch_log_group" "agentcore_runtime" {
  name              = "/aws/bedrock/agentcore/runtime"
  retention_in_days = 2555  # 7 years

  tags = {
    RWWHW      = "How"
    Framework = "Resilience"
  }
}

resource "aws_cloudwatch_log_group" "rwwhw_audit" {
  name              = "/aws/rwwhw/audit"
  retention_in_days = 2555

  tags = {
    RWWHW      = "Evidence"
    Framework = "Compliance"
  }
}

# Lambda for Circuit Breaker (How)
resource "aws_lambda_function" "circuit_breaker" {
  function_name = "${var.project_name}-circuit-breaker"
  role          = aws_iam_role.lambda_role.arn
  handler       = "index.handler"
  runtime       = "python3.11"
  timeout       = 30

  filename         = data.archive_file.lambda_circuit_breaker.output_path
  source_code_hash = data.archive_file.lambda_circuit_breaker.output_base64sha256

  environment {
    variables = {
      ERROR_THRESHOLD     = "0.1"
      LATENCY_THRESHOLD   = "3000"
      FALLBACK_AGENT      = var.fallback_agent_name
      NOTIFICATION_TOPIC  = aws_sns_topic.incident_alerts.arn
    }
  }

  tags = {
    RWWHW      = "How"
    Framework = "Resilience"
  }
}

# Lambda for Evidence Package Generator (What Evidence)
resource "aws_lambda_function" "evidence_generator" {
  function_name = "${var.project_name}-evidence-generator"
  role          = aws_iam_role.lambda_role.arn
  handler       = "index.handler"
  runtime       = "python3.11"
  timeout       = 60

  filename         = data.archive_file.lambda_evidence.output_path
  source_code_hash = data.archive_file.lambda_evidence.output_base64sha256

  environment {
    variables = {
      EVIDENCE_BUCKET = aws_s3_bucket.rwwhw_evidence.id
      AUDIT_TABLE     = aws_dynamodb_table.session_memory.name
    }
  }

  tags = {
    RWWHW      = "Evidence"
    Framework = "Compliance"
  }
}

# Step Functions for Human Review (How)
resource "aws_sfn_state_machine" "human_review" {
  name     = "${var.project_name}-human-review"
  role_arn = aws_iam_role.step_functions_role.arn

  definition = jsonencode({
    Comment = "RWWHW Human Review Workflow"
    StartAt = "AssessSeverity"
    States = {
      AssessSeverity = {
        Type     = "Task"
        Resource = aws_lambda_function.circuit_breaker.arn
        Next     = "RouteBySeverity"
      }
      RouteBySeverity = {
        Type = "Choice"
        Choices = [
          {
            Variable = "$.severity"
            StringEquals = "CRITICAL"
            Next = "ImmediateEscalation"
          },
          {
            Variable = "$.severity"
            StringEquals = "HIGH"
            Next = "CROReview"
          },
          {
            Variable = "$.severity"
            StringEquals = "MEDIUM"
            Next = "RiskTeamReview"
          }
        ]
        Default = "AutoResolve"
      }
      ImmediateEscalation = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:sns:publish"
        Parameters = {
          TopicArn = aws_sns_topic.incident_alerts.arn
          Message  = "CRITICAL: AI incident requires immediate attention"
        }
        Next = "WaitForHumanDecision"
      }
      CROReview = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:sns:publish"
        Parameters = {
          TopicArn = aws_sns_topic.cro_alerts.arn
          Message  = "HIGH: AI incident requires CRO review"
        }
        Next = "WaitForHumanDecision"
      }
      RiskTeamReview = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:sns:publish"
        Parameters = {
          TopicArn = aws_sns_topic.risk_team_alerts.arn
          Message  = "MEDIUM: AI incident requires risk team review"
        }
        Next = "WaitForHumanDecision"
      }
      WaitForHumanDecision = {
        Type = "Task"
        Resource = "arn:aws:states:::aws-sdk:sfn:waitForTaskToken"
        TimeoutSeconds = 86400
        Next = "GenerateEvidence"
      }
      GenerateEvidence = {
        Type     = "Task"
        Resource = aws_lambda_function.evidence_generator.arn
        End      = true
      }
      AutoResolve = {
        Type = "Pass"
        End  = true
      }
    }
  })

  tags = {
    RWWHW      = "How"
    Framework = "Governance"
  }
}

# SNS Topics for Alerts
resource "aws_sns_topic" "incident_alerts" {
  name = "${var.project_name}-incident-alerts"
}

resource "aws_sns_topic" "cro_alerts" {
  name = "${var.project_name}-cro-alerts"
}

resource "aws_sns_topic" "risk_team_alerts" {
  name = "${var.project_name}-risk-team-alerts"
}

# CloudWatch Dashboard (30-Second Answers)
resource "aws_cloudwatch_dashboard" "rwwhw" {
  dashboard_name = "${var.project_name}-governance"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 1
        properties = {
          markdown = "# RWWHW AI Governance Dashboard - Answer 4 Questions in 30 Seconds"
        }
      },
      {
        type   = "query"
        x      = 0
        y      = 1
        width  = 6
        height = 6
        properties = {
          title  = "RWWHW #1: What Was It Trying To Do?"
          query  = "SOURCE '/aws/bedrock/agentcore/sessions' | fields agent_goal, reasoning_chain | filter incident_flag = true | sort timestamp desc | limit 10"
          region = var.aws_region
        }
      },
      {
        type   = "query"
        x      = 6
        y      = 1
        width  = 6
        height = 6
        properties = {
          title  = "RWWHW #2: Who Owned It, What Rule Failed?"
          query  = "SOURCE '/aws/bedrock/guardrails' | fields rule_failed, business_owner, risk_owner | sort timestamp desc | limit 10"
          region = var.aws_region
        }
      },
      {
        type   = "query"
        x      = 12
        y      = 1
        width  = 6
        height = 6
        properties = {
          title  = "RWWHW #3: How We Stopped & Recovered"
          query  = "SOURCE '/aws/bedrock/circuit-breakers' | fields stop_mechanism, recovery_method, human_reviewer | sort timestamp desc | limit 10"
          region = var.aws_region
        }
      },
      {
        type   = "metric"
        x      = 18
        y      = 1
        width  = 6
        height = 6
        properties = {
          title  = "RWWHW #4: Evidence Integrity"
          metrics = [
            ["AWS/S3", "ObjectLockRetention", "BucketName", aws_s3_bucket.rwwhw_evidence.id]
          ]
          region = var.aws_region
        }
      }
    ]
  })
}
