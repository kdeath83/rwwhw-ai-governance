# WWHW AI Governance Framework

> **What** was it trying to do? **Who** owned it? **How** did you stop/recover? **What** does the evidence show?

A production-ready AWS-native AI governance solution built on Bedrock AgentCore, designed to answer these four critical questions in 30 seconds during an AI incident.

## The WWHW Framework

| Question | Why It Matters | AWS Service |
|----------|---------------|-------------|
| **What** was it trying to do? | Intent, reasoning, decision path | Bedrock AgentCore Memory + Session Trace |
| **Who** owned it, what rule failed? | Accountability, governance, compliance | AgentCore Registry + Guardrails |
| **How** did you stop/recover? | Operational resilience, circuit breakers | AgentCore Runtime + Step Functions |
| **What** does the evidence show? | Immutable audit trail, legal proof | S3 Object Lock + CloudTrail + Athena |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Bedrock AgentCore                        │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │   Memory     │  │   Registry   │  │   Runtime    │      │
│  │  (What)      │  │  (Who)       │  │  (How)       │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
└────────────────────┬────────────────────────────────────────┘
                     │
    ┌────────────────┼────────────────┐
    │                │                │
┌───▼────┐     ┌────▼────┐     ┌────▼────┐
│Guardrails│     │EventBridge│     │Step Functions│
│(Rules)  │     │(Triggers) │     │(Human Review)│
└───┬────┘     └────┬────┘     └────┬────┘
    │               │               │
┌───▼───────────────▼───────────────▼────┐
│           S3 + DynamoDB                 │
│     (What Evidence - 7 years)            │
└─────────────────────────────────────────┘
```

## Quick Start

### Option 1: Terraform

```bash
cd terraform/
terraform init
terraform plan -var="environment=production"
terraform apply
```

### Option 2: CDK

```bash
cd cdk/
npm install
npx cdk bootstrap
npx cdk deploy
```

## What Gets Deployed

### 1. AgentCore Registry (Who)
- DynamoDB table for agent ownership and governance
- Required fields: technical_owner, business_owner, risk_owner
- Guardrail associations and approval workflows

### 2. WWHW Audit System (What Evidence)
- S3 bucket with Object Lock (7-year retention)
- CloudWatch Logs for session traces
- Athena tables for compliance queries
- CloudTrail integration for API auditing

### 3. Circuit Breakers (How)
- Lambda functions for runtime monitoring
- EventBridge rules for anomaly detection
- Step Functions for human review workflows
- SNS topics for incident alerting

### 4. Dashboard (30-Second Answers)
- CloudWatch dashboard with 4 WWHW sections
- Real-time incident response view
- One-click evidence package generation

## Example: Answer All 4 Questions

```python
import boto3
from rwwhw import generate_incident_report

# After an AI incident
report = generate_incident_report(
    session_id="loan-approval-2026-05-02-001",
    timestamp="2026-05-02T14:32:11Z"
)

print(report.what)      # "Assessing $500k loan, debt ratio 4.2x exceeded 4.0x policy"
print(report.who)      # "Credit Risk Committee owns rule, CRO notified"
print(report.how)      # "Guardrail blocked at 14:32:11, human approved override at 14:47:33"
print(report.evidence) # "SHA256 verified, Object Lock until 2033"
```

## Cost Estimate

| Component | Monthly Cost |
|-----------|--------------|
| Bedrock AgentCore | ~$50-100 |
| DynamoDB | ~$10-20 |
| S3 (7-year retention) | ~$5-15 |
| CloudWatch | ~$10-30 |
| **Total** | **~$75-165** |

## License

MIT License — for FSI/Regulated industry use.

## Source

Built on AWS Bedrock AgentCore — native AWS AI governance platform.


# History

Originally created as WWHW AI Governance Framework, renamed to RWWHW AI Governance Framework.
