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

# ═══════════════════════════════════════════════════════════════
# RWWHW AI Governance Framework for Bedrock AgentCore
# ═══════════════════════════════════════════════════════════════
# 
# This deployment creates the GOVERNANCE LAYER on top of 
# AWS Bedrock AgentCore native services:
# - Agent Registry (Who) - Uses AWS Agent Registry API
# - AgentCore Memory (What) - Uses native Bedrock Memory service
# - AgentCore Runtime (How) - Monitors via CloudWatch, controls via APIs
# - S3 Evidence (What Evidence) - Immutable audit trail

# ═══════════════════════════════════════════════════════════════
# S3 Bucket for Evidence (7-year retention)
# ═══════════════════════════════════════════════════════════════

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
      days = var.retention_days
    }
  }
}

resource "aws_s3_bucket_policy" "rwwhw_evidence" {
  bucket = aws_s3_bucket.rwwhw_evidence.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyDeleteLockedObjects"
        Effect = "Deny"
        Principal = "*"
        Action   = "s3:DeleteObject"
        Resource = "${aws_s3_bucket.rwwhw_evidence.arn}/*"
        Condition = {
          StringEquals = {
            "s3:object-lock-mode" = "COMPLIANCE"
          }
        }
      },
      {
        Sid    = "AllowLambdaEvidenceWrite"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.lambda_role.arn
        }
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "${aws_s3_bucket.rwwhw_evidence.arn}/evidence/*"
      }
    ]
  })
}

# ═══════════════════════════════════════════════════════════════
# CloudWatch Log Groups for Bedrock AgentCore Integration
# ═══════════════════════════════════════════════════════════════

# Bedrock AgentCore Runtime logs (native service)
resource "aws_cloudwatch_log_group" "agentcore_runtime" {
  name              = "/aws/bedrock/agentcore/runtime"
  retention_in_days = var.retention_days

  tags = {
    RWWHW      = "How"
    Framework = "Resilience"
    Service   = "BedrockAgentCore"
  }
}

# Bedrock Guardrails logs (native service)
resource "aws_cloudwatch_log_group" "guardrails" {
  name              = "/aws/bedrock/guardrails"
  retention_in_days = var.retention_days

  tags = {
    RWWHW      = "Who"
    Framework = "Governance"
    Service   = "BedrockGuardrails"
  }
}

# Bedrock AgentCore Memory session traces
resource "aws_cloudwatch_log_group" "agentcore_memory" {
  name              = "/aws/bedrock/agentcore/sessions"
  retention_in_days = var.retention_days

  tags = {
    RWWHW      = "What"
    Framework = "Governance"
    Service   = "BedrockAgentCoreMemory"
  }
}

# RWWHW Audit log (for evidence generation tracking)
resource "aws_cloudwatch_log_group" "rwwhw_audit" {
  name              = "/aws/rwwhw/audit"
  retention_in_days = var.retention_days

  tags = {
    RWWHW      = "Evidence"
    Framework = "Compliance"
  }
}

# ═══════════════════════════════════════════════════════════════
# IAM Roles
# ═══════════════════════════════════════════════════════════════

# Lambda execution role with Bedrock AgentCore permissions
resource "aws_iam_role" "lambda_role" {
  name = "${var.project_name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_bedrock_policy" {
  name = "${var.project_name}-lambda-bedrock-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BedrockAgentCoreAccess"
        Effect = "Allow"
        Action = [
          "bedrock:GetAgent",
          "bedrock:ListAgents",
          "bedrock:UpdateAgent",
          "bedrock:InvokeAgent",
          "bedrock-agentcore:GetRegistryRecord",
          "bedrock-agentcore:ListRegistryRecords",
          "bedrock-agentcore:SearchRegistry",
          "bedrock-agentcore-runtime:GetAgentMemory",
          "bedrock-agentcore-runtime:ListAgentMemory"
        ]
        Resource = "*"
      },
      {
        Sid    = "BedrockGuardrailsAccess"
        Effect = "Allow"
        Action = [
          "bedrock:GetGuardrail",
          "bedrock:ListGuardrails",
          "bedrock:GetGuardrailVersion"
        ]
        Resource = "*"
      },
      {
        Sid    = "CloudWatchMetrics"
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:PutMetricData",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:FilterLogEvents"
        ]
        Resource = "*"
      },
      {
        Sid    = "S3EvidenceAccess"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:GetObjectAttributes"
        ]
        Resource = "${aws_s3_bucket.rwwhw_evidence.arn}/*"
      },
      {
        Sid    = "SNSNotifications"
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = [
          aws_sns_topic.incident_alerts.arn,
          aws_sns_topic.cro_alerts.arn,
          aws_sns_topic.risk_team_alerts.arn
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Step Functions role
resource "aws_iam_role" "step_functions_role" {
  name = "${var.project_name}-stepfunctions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "states.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "step_functions_policy" {
  name = "${var.project_name}-stepfunctions-policy"
  role = aws_iam_role.step_functions_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction",
          "sns:Publish"
        ]
        Resource = "*"
      }
    ]
  })
}

# ═══════════════════════════════════════════════════════════════
# Lambda Functions
# ═══════════════════════════════════════════════════════════════

# Package Lambda functions
data "archive_file" "lambda_circuit_breaker" {
  type        = "zip"
  source_file = "${path.module}/lambda/circuit_breaker.py"
  output_path = "${path.module}/lambda/circuit_breaker.zip"
}

data "archive_file" "lambda_evidence" {
  type        = "zip"
  source_file = "${path.module}/lambda/evidence_generator.py"
  output_path = "${path.module}/lambda/evidence_generator.zip"
}

# Circuit Breaker Lambda — Monitors Bedrock AgentCore Runtime
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
      REGISTRY_NAME       = var.project_name
    }
  }

  tags = {
    RWWHW      = "How"
    Framework = "Resilience"
    Service   = "BedrockAgentCore"
  }
}

# Evidence Generator Lambda — Packages Bedrock AgentCore data
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
      EVIDENCE_BUCKET    = aws_s3_bucket.rwwhw_evidence.id
      REGISTRY_NAME      = var.project_name
      LOG_GROUP_MEMORY   = aws_cloudwatch_log_group.agentcore_memory.name
      LOG_GROUP_GUARD    = aws_cloudwatch_log_group.guardrails.name
    }
  }

  tags = {
    RWWHW      = "Evidence"
    Framework = "Compliance"
    Service   = "BedrockAgentCore"
  }
}

# ═══════════════════════════════════════════════════════════════
# Step Functions — Human Review Workflow
# ═══════════════════════════════════════════════════════════════

resource "aws_sfn_state_machine" "human_review" {
  name     = "${var.project_name}-human-review"
  role_arn = aws_iam_role.step_functions_role.arn

  definition = jsonencode({
    Comment = "RWWHW Human Review Workflow for Bedrock AgentCore Incidents"
    StartAt = "AssessSeverity"
    States = {
      AssessSeverity = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.circuit_breaker.arn
          Payload = {
            "agent_id.$" = "$.agent_id"
            "session_id.$" = "$.session_id"
            "check_only" = true
          }
        }
        Next     = "RouteBySeverity"
      }
      RouteBySeverity = {
        Type = "Choice"
        Choices = [
          {
            Variable = "$.Payload.severity"
            StringEquals = "CRITICAL"
            Next = "ImmediateEscalation"
          },
          {
            Variable = "$.Payload.severity"
            StringEquals = "HIGH"
            Next = "CROReview"
          },
          {
            Variable = "$.Payload.severity"
            StringEquals = "MEDIUM"
            Next = "RiskTeamReview"
          }
        ]
        Default = "AutoResolve"
      }
      ImmediateEscalation = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn = aws_sns_topic.incident_alerts.arn
          Message = {
            "alert_type" = "CRITICAL"
            "message" = "Bedrock AgentCore incident requires immediate attention"
            "agent_id.$" = "$.agent_id"
          }
        }
        Next = "WaitForHumanDecision"
      }
      CROReview = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn = aws_sns_topic.cro_alerts.arn
          Message = {
            "alert_type" = "HIGH"
            "message" = "Bedrock AgentCore incident requires CRO review"
            "agent_id.$" = "$.agent_id"
          }
        }
        Next = "WaitForHumanDecision"
      }
      RiskTeamReview = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn = aws_sns_topic.risk_team_alerts.arn
          Message = {
            "alert_type" = "MEDIUM"
            "message" = "Bedrock AgentCore incident requires risk team review"
            "agent_id.$" = "$.agent_id"
          }
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
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.evidence_generator.arn
          Payload = {
            "incident_id.$" = "$.incident_id"
            "session_id.$" = "$.session_id"
            "agent_id.$" = "$.agent_id"
            "human_decision.$" = "$.human_decision"
          }
        }
        End = true
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
    Service   = "BedrockAgentCore"
  }
}

# ═══════════════════════════════════════════════════════════════
# SNS Topics for Alerts
# ═══════════════════════════════════════════════════════════════

resource "aws_sns_topic" "incident_alerts" {
  name = "${var.project_name}-incident-alerts"
  
  tags = {
    RWWHW = "How"
    Type  = "Critical"
  }
}

resource "aws_sns_topic" "cro_alerts" {
  name = "${var.project_name}-cro-alerts"
  
  tags = {
    RWWHW = "Who"
    Type  = "High"
  }
}

resource "aws_sns_topic" "risk_team_alerts" {
  name = "${var.project_name}-risk-team-alerts"
  
  tags = {
    RWWHW = "Who"
    Type  = "Medium"
  }
}

# ═══════════════════════════════════════════════════════════════
# CloudWatch Dashboard — 30-Second Answers
# ═══════════════════════════════════════════════════════════════

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
          markdown = "# RWWHW AI Governance for Bedrock AgentCore — Answer 4 Questions in 30 Seconds"
        }
      },
      {
        type   = "text"
        x      = 0
        y      = 1
        width  = 24
        height = 1
        properties = {
          markdown = "**Bedrock AgentCore Services:** [Memory](https://console.aws.amazon.com/bedrock/memory) | [Registry](https://console.aws.amazon.com/bedrock/registry) | [Runtime](https://console.aws.amazon.com/bedrock/runtime) | [Guardrails](https://console.aws.amazon.com/bedrock/guardrails)"
        }
      },
      # RWWHW #1: What — Bedrock AgentCore Memory
      {
        type   = "logQuery"
        x      = 0
        y      = 2
        width  = 6
        height = 6
        properties = {
          title  = "RWWHW #1: WHAT — Bedrock AgentCore Memory"
          query  = "SOURCE '/aws/bedrock/agentcore/sessions' | fields @timestamp, agent_id, session_goal, reasoning_summary | filter strcontains(@message, 'incident') or strcontains(@message, 'guardrail_block') | sort @timestamp desc | limit 10"
          region = var.aws_region
        }
      },
      # RWWHW #2: Who — Bedrock Guardrails + Agent Registry
      {
        type   = "logQuery"
        x      = 6
        y      = 2
        width  = 6
        height = 6
        properties = {
          title  = "RWWHW #2: WHO — Guardrails & Registry"
          query  = "SOURCE '/aws/bedrock/guardrails' | fields @timestamp, guardrail_id, rule_triggered, technical_owner, business_owner | filter action == 'BLOCKED' | sort @timestamp desc | limit 10"
          region = var.aws_region
        }
      },
      # RWWHW #3: How — Bedrock AgentCore Runtime
      {
        type   = "metric"
        x      = 12
        y      = 2
        width  = 6
        height = 6
        properties = {
          title  = "RWWHW #3: HOW — AgentCore Runtime Health"
          metrics = [
            ["AWS/Bedrock", "InvocationErrors", "AgentId", "*", { "stat": "Sum", "period": 60 }],
            ["AWS/Bedrock", "Latency", "AgentId", "*", { "stat": "Average", "period": 60, "yAxis": "right" }]
          ]
          region = var.aws_region
          annotations = {
            horizontal = [
              { value = 0.1, label = "Error Threshold", color = "#d62728" },
              { value = 3000, yAxis = "right", label = "Latency Threshold", color = "#ff7f0e" }
            ]
          }
        }
      },
      # RWWHW #4: Evidence — S3 Object Lock
      {
        type   = "metric"
        x      = 18
        y      = 2
        width  = 6
        height = 6
        properties = {
          title  = "RWWHW #4: EVIDENCE — S3 Integrity"
          metrics = [
            ["AWS/S3", "NumberOfObjects", "BucketName", aws_s3_bucket.rwwhw_evidence.id, { "stat": "Average" }],
            ["AWS/S3", "BucketSizeBytes", "BucketName", aws_s3_bucket.rwwhw_evidence.id, { "stat": "Average", "yAxis": "right" }]
          ]
          region = var.aws_region
        }
      },
      # Evidence Generation Log
      {
        type   = "logQuery"
        x      = 0
        y      = 8
        width  = 24
        height = 4
        properties = {
          title  = "Evidence Packages Generated"
          query  = "SOURCE '/aws/rwwhw/audit' | fields @timestamp, incident_id, agent_id, evidence_location, integrity_hash | filter strcontains(@message, 'EVIDENCE_GENERATED') | sort @timestamp desc | limit 20"
          region = var.aws_region
        }
      }
    ]
  })
}

# ═══════════════════════════════════════════════════════════════
# EventBridge Rules — Trigger on Bedrock Events
# ═══════════════════════════════════════════════════════════════

# Trigger circuit breaker on Guardrail block
resource "aws_cloudwatch_event_rule" "guardrail_block" {
  name        = "${var.project_name}-guardrail-block"
  description = "Trigger workflow when Bedrock Guardrail blocks an agent"

  event_pattern = jsonencode({
    source      = ["aws.bedrock"]
    detail-type = ["Guardrail Intercepted"]
  })
}

resource "aws_cloudwatch_event_target" "guardrail_to_sns" {
  rule = aws_cloudwatch_event_rule.guardrail_block.name
  arn  = aws_sns_topic.incident_alerts.arn
}

# Trigger on AgentCore Runtime error
resource "aws_cloudwatch_event_rule" "runtime_error" {
  name        = "${var.project_name}-runtime-error"
  description = "Trigger workflow on Bedrock AgentCore Runtime errors"

  event_pattern = jsonencode({
    source      = ["aws.bedrock"]
    detail-type = ["Agent Runtime Error"]
  })
}
