# RWWHW AI Governance Framework for Amazon Bedrock AgentCore

> **What** was it trying to do? **Who** owned it? **How** did you stop/recover? **What** does the evidence show?

A production-ready AI governance solution **native to AWS Bedrock AgentCore**. Answers all four questions in 30 seconds during an AI incident by leveraging the actual Bedrock AgentCore services — Registry, Memory, Runtime, and Guardrails.

## 🚀 One-Click Deploy

Deploy the full governance layer in ~5 minutes:

### Option 1: CloudFormation Console (Easiest)

[![Launch Stack](https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png)](https://console.aws.amazon.com/cloudformation/home#/stacks/create/review?templateURL=https://raw.githubusercontent.com/kdeath83/rwwhw-ai-governance/main/cloudformation/rwwhw-template.yaml&stackName=rwwhw-ai-governance)

**Steps:**
1. Click "Launch Stack" button above ☝️
2. Sign in to AWS Console
3. Review parameters (Registry name, retention days)
4. Check "I acknowledge..." for IAM resources
5. Click **Create stack**
6. Wait ~3 minutes for deployment

### Option 2: AWS CLI (Script)

```bash
# Clone repo
git clone https://github.com/kdeath83/rwwhw-ai-governance.git
cd rwwhw-ai-governance

# One-click deploy
./deploy.sh

# Or with custom options:
./deploy.sh --region ap-southeast-2 --stack-name my-governance
```

**Windows (PowerShell):**
```powershell
.\deploy.ps1 -Region ap-southeast-2
```

### Option 3: Terraform / CDK

See [Infrastructure Options](#infrastructure-options) below for Terraform/CDK deployment.

## Prerequisites

- AWS Account with Bedrock AgentCore access (see [enrollment](#enrollment))
- AWS CLI v2+ configured
- For CDK: Node.js 18+, AWS CDK v2
- For Terraform: Terraform 1.5+

## The RWWHW Framework

| Question | Why It Matters | Bedrock AgentCore Service |
|----------|---------------|---------------------------|
| **What** was it trying to do? | Intent, reasoning, decision path | [AgentCore Memory](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/memory.html) — Session traces & reasoning chains |
| **Who** owned it, what rule failed? | Accountability, governance | [Agent Registry](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/registry.html) — Ownership metadata + [Guardrails](https://docs.aws.amazon.com/bedrock/latest/userguide/guardrails.html) |
| **How** did you stop/recover? | Operational resilience | [AgentCore Runtime](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime.html) — Circuit breakers + Step Functions |
| **What** does the evidence show? | Immutable audit trail | S3 Object Lock + [CloudTrail](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/logging-using-cloudtrail.html) |

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                     Amazon Bedrock AgentCore                         │
│                                                                      │
│  ┌────────────────┐  ┌──────────────┐  ┌──────────────┐  ┌─────────┐  │
│  │   Memory       │  │  Registry    │  │   Runtime    │  │Guardrails│ │
│  │  (What)        │  │  (Who)       │  │  (How)       │  │ (Rules)  │ │
│  │                │  │              │  │              │  │          │ │
│  │ • Sessions     │  │ • Agents     │  │ • Execution  │  │ • Blocks │ │
│  │ • Traces       │  │ • Tools      │  │ • Monitoring │  │ • Traces │ │
│  │ • Reasoning    │  │ • Ownership  │  │ • Circuit    │  │          │ │
│  └────────────────┘  └──────────────┘  └──────────────┘  └─────────┘  │
│           │                 │                 │              │         │
│           └─────────────────┴─────────────────┴──────────────┘         │
│                              │                                       │
└──────────────────────────────┼───────────────────────────────────────┘
                               │
                    ┌──────────▼──────────┐
                    │   RWWHW Governance  │
                    │      Layer          │
                    ├─────────────────────┤
                    │ • Evidence S3       │
                    │ • CloudWatch        │
                    │ • Step Functions    │
                    │ • SNS Alerts        │
                    └─────────────────────┘
```

## Quick Start

### Step 1: Enable Bedrock AgentCore (One-time)

Bedrock AgentCore requires account enrollment. Choose your region:

```bash
# Check if AgentCore is available in your region
aws bedrock-agentcore list-registries --region us-east-1

# If "AccessDeniedException", request access via:
# AWS Console → Amazon Bedrock → AgentCore → "Get Started"
```

Supported regions: `us-east-1`, `us-west-2`, `eu-west-1`, `ap-southeast-2` (see [docs](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/regions.html))

### Step 2: Deploy RWWHW Governance Layer

#### Option A: Terraform

```bash
cd terraform/

# Initialize
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your settings

terraform init
terraform plan
terraform apply

# Output will show:
# - Evidence bucket name
# - Registry integration role ARN
# - Dashboard URL
```

#### Option B: CDK

```bash
cd cdk/
npm install

# Bootstrap CDK (first time only)
npx cdk bootstrap aws://ACCOUNT/REGION

# Deploy
npx cdk deploy

# Outputs will show:
# - RwwhwAiGovernanceStack.EvidenceBucket
# - RwwhwAiGovernanceStack.DashboardUrl
```

### Step 3: Register Your Agents (Who)

```bash
# Use the provided registration script
python scripts/register_agent.py \
  --agent-name "loan-assistant-v1" \
  --technical-owner "platform-team@company.com" \
  --business-owner "lending-team@company.com" \
  --risk-owner "cro@company.com" \
  --risk-classification "HIGH" \
  --guardrail-id "gr-xxxxx"

# Verify registration
aws bedrock-agentcore get-registry-record \
  --registry-name "rwwhw-ai-governance" \
  --record-id "loan-assistant-v1"
```

### Step 4: Configure Session Memory (What)

When creating agents via Bedrock Console or API, enable AgentCore Memory:

```python
import boto3

bedrock = boto3.client('bedrock-agent')

bedrock.create_agent(
    agentName='loan-assistant-v1',
    description='Loan approval assistant with governance',
    idleSessionTTLInSeconds=1800,
    # Enable AgentCore Memory for session traces
    memoryConfiguration={
        'enabled': True,
        'storageDuration': 2555  # 7 years for compliance
    },
    # Attach Guardrails for "Who" tracking
    guardrailConfiguration={
        'guardrailIdentifier': 'gr-xxxxx',
        'guardrailVersion': 'DRAFT'
    }
)
```

### Step 5: Runtime Monitoring (How)

The deployed Lambda functions automatically monitor your Bedrock AgentCore Runtime:

```python
# Circuit breaker monitors Bedrock Runtime metrics
def check_runtime_health(agent_id):
    """
    Monitors Bedrock AgentCore Runtime via CloudWatch:
    - Invocation errors
    - Latency spikes
    - Guardrail violations
    """
    cloudwatch = boto3.client('cloudwatch')
    
    # Query Bedrock Runtime metrics
    metrics = cloudwatch.get_metric_statistics(
        Namespace='AWS/Bedrock/AgentCore',
        MetricName='RuntimeErrors',
        Dimensions=[
            {'Name': 'AgentId', 'Value': agent_id}
        ],
        StartTime=datetime.utcnow() - timedelta(minutes=5),
        EndTime=datetime.utcnow(),
        Period=60,
        Statistics=['Sum']
    )
    
    if metrics['Datapoints'] and metrics['Datapoints'][0]['Sum'] > threshold:
        # Trigger circuit breaker via AgentCore Runtime API
        bedrock_runtime = boto3.client('bedrock-agent-runtime')
        bedrock_runtime.update_agent(
            agentId=agent_id,
            agentStatus='DISABLED'
        )
```

### Step 6: View Dashboard (30-Second Answers)

Open the CloudWatch Dashboard URL from deployment outputs:

```bash
# Get dashboard URL
terraform output dashboard_url
# or
aws cloudwatch get-dashboard --dashboard-name rwwhw-ai-governance-governance
```

Dashboard queries Bedrock AgentCore native log groups:
- `/aws/bedrock/agentcore/sessions` — What
- `/aws/bedrock/guardrails` — Who
- `/aws/bedrock/agentcore/runtime` — How

## Example: Answer All 4 Questions

```python
import boto3
from scripts.rwwhw_evidence import generate_incident_report

# After an AI incident
report = generate_incident_report(
    session_id="loan-approval-2026-05-02-001",
    agent_id="loan-assistant-v1"
)

print("=" * 60)
print(f"INCIDENT: {report.incident_id}")
print("=" * 60)

# RWWHW #1: What (from AgentCore Memory)
print(f"\n🎯 WHAT: {report.what}")
# Output: "Assessing $500k loan, debt ratio 4.2x exceeded 4.0x policy"
# Source: Bedrock AgentCore Memory session trace

# RWWHW #2: Who (from Agent Registry + Guardrails)
print(f"\n👤 WHO: {report.who}")
# Output: "Credit Risk Committee owns rule, CRO notified"
# Source: AWS Agent Registry ownership + Guardrail trace

# RWWHW #3: How (from AgentCore Runtime)
print(f"\n🛡️ HOW: {report.how}")
# Output: "Guardrail blocked at 14:32:11, human approved override at 14:47:33"
# Source: Bedrock AgentCore Runtime circuit breaker + Step Functions

# RWWHW #4: Evidence (from S3 + CloudTrail)
print(f"\n📁 EVIDENCE: {report.evidence}")
# Output: "s3://rwwhw-evidence/2026/05/02/incident-001/evidence.json"
#         "SHA256: a3f5d2... | CloudTrail: ct-xxx"
print(f"   SHA256: {report.integrity_hash}")
print(f"   Retention: 7 years (S3 Object Lock until 2033)")
```

## What Gets Deployed

### 1. AWS Agent Registry Integration (Who)
- **Registry**: `rwwhw-ai-governance` (created if not exists)
- **IAM Role**: Allows Lambda to query registry records
- **Metadata**: Technical owner, business owner, risk owner, guardrail associations

### 2. Bedrock AgentCore Memory Integration (What)
- **No custom infra** — uses native Bedrock AgentCore Memory service
- **Log Groups**: `/aws/bedrock/agentcore/sessions` (7-year retention)
- **Dashboard queries**: Native Memory session traces

### 3. Bedrock AgentCore Runtime Monitoring (How)
- **Circuit Breaker Lambda**: Monitors Runtime metrics, disables agents on anomalies
- **Step Functions**: Human approval workflows
- **EventBridge**: Triggers on Guardrail violations

### 4. Evidence System (What Evidence)
- **S3 Bucket**: Object Lock enabled, 7-year compliance retention
- **CloudTrail**: All Bedrock AgentCore API calls logged
- **Evidence Generator**: Packages Memory + Registry + Runtime data with SHA256

## IAM Permissions Required

Your deployment role needs:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "bedrock:GetAgent",
        "bedrock:ListAgents",
        "bedrock:UpdateAgent",
        "bedrock:InvokeAgent",
        "bedrock-agentcore:*",
        "bedrock-agentcore-runtime:*"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "bedrock:GetGuardrail",
        "bedrock:ListGuardrails",
        "bedrock:ApplyGuardrail"
      ],
      "Resource": "*"
    }
  ]
}
```

## Cost Estimate

| Component | Monthly Cost | Notes |
|-----------|--------------|-------|
| Bedrock AgentCore Runtime | ~$50-150 | Based on agent invocations |
| Bedrock AgentCore Memory | ~$10-30 | Session storage |
| AWS Agent Registry | $0 | No charge for registry |
| Guardrails | ~$5-15 | Per 1,000 processed text units |
| S3 (7-year retention) | ~$5-15 | Evidence storage |
| CloudWatch | ~$10-30 | Logs + Dashboard |
| **Total** | **~$80-240** | |

## Troubleshooting

### "AgentCore not enabled in region"
```bash
# Check available regions
aws bedrock-agentcore list-registries --region us-east-1

# If error, request access:
# AWS Console → Amazon Bedrock → AgentCore → "Get Started"
```

### "AccessDeniedException: bedrock-agentcore:GetRegistryRecord"
```bash
# Add AgentCore permissions to your role
aws iam attach-role-policy \
  --role-name YourDeploymentRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonBedrockAgentCoreFullAccess
```

### Dashboard shows no data
```bash
# Verify Bedrock AgentCore logging is enabled
aws bedrock get-agent --agent-id your-agent-id
# Check: memoryConfiguration.enabled == true
```

## Documentation

- [Bedrock AgentCore Overview](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/what-is-bedrock-agentcore.html)
- [Agent Registry](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/registry.html)
- [AgentCore Memory](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/memory.html)
- [AgentCore Runtime](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime.html)
- [Guardrails](https://docs.aws.amazon.com/bedrock/latest/userguide/guardrails.html)

## License

MIT License — for FSI/Regulated industry use.

---

**Built natively on AWS Bedrock AgentCore** — Not a wrapper, not an abstraction. Uses the actual services.
