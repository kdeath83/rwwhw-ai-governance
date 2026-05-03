#!/usr/bin/env python3
"""
RWWHW AI Governance Framework — Agent Registration Script
Registers agents with AWS Bedrock Agent Registry for governance tracking

Usage:
    python register_agent.py \\
        --agent-name "loan-assistant-v1" \\
        --technical-owner "platform@company.com" \\
        --business-owner "lending@company.com" \\
        --risk-owner "cro@company.com" \\
        --risk-classification "HIGH" \\
        --guardrail-id "gr-xxxxx"

Requires:
    - AWS CLI configured with Bedrock AgentCore permissions
    - boto3 installed
"""

import argparse
import json
import sys
from datetime import datetime

try:
    import boto3
    from botocore.exceptions import ClientError
except ImportError:
    print("Error: boto3 required. Install with: pip install boto3")
    sys.exit(1)


def get_or_create_registry(registry_name: str, region: str = None) -> str:
    """Get existing registry or create new one for RWWHW governance."""
    client = boto3.client('bedrock-agentcore', region_name=region)
    
    try:
        # Try to get existing registry
        response = client.get_registry(registryName=registry_name)
        print(f"✓ Using existing registry: {registry_name}")
        return response['registry']['registryArn']
    except ClientError as e:
        if e.response['Error']['Code'] == 'ResourceNotFoundException':
            # Create new registry
            try:
                response = client.create_registry(
                    registryName=registry_name,
                    description=f"RWWHW AI Governance Registry — tracks agent ownership and compliance metadata",
                    tags={
                        'Framework': 'RWWHW',
                        'Purpose': 'AI-Governance',
                        'Compliance': 'APRA-Aligned'
                    }
                )
                print(f"✓ Created registry: {registry_name}")
                return response['registry']['registryArn']
            except ClientError as create_error:
                if 'AccessDeniedException' in str(create_error):
                    print(f"✗ Access denied. Ensure Bedrock AgentCore is enabled in {region or 'your region'}.")
                    print("  AWS Console → Amazon Bedrock → AgentCore → 'Get Started'")
                    sys.exit(1)
                raise
        raise


def register_agent(args, registry_arn: str) -> dict:
    """Register agent with AWS Bedrock Agent Registry."""
    client = boto3.client('bedrock-agentcore')
    
    record_id = f"{args.agent_name}-v{args.version}"
    
    # Build metadata for RWWHW governance
    metadata = {
        'agentName': args.agent_name,
        'version': args.version,
        'technicalOwner': args.technical_owner,
        'businessOwner': args.business_owner,
        'riskOwner': args.risk_owner,
        'riskClassification': args.risk_classification,
        'guardrailId': args.guardrail_id,
        'guardrailVersion': args.guardrail_version,
        'businessUnit': args.business_unit,
        'approvalWorkflow': args.approval_workflow,
        'retentionDays': str(args.retention_days),
        'registeredAt': datetime.utcnow().isoformat(),
        'registryName': args.registry_name,
        'framework': 'RWWHW'
    }
    
    # Resource URI for Bedrock Agent
    resource_uri = f"arn:aws:bedrock:{boto3.session.Session().region_name}:{boto3.client('sts').get_caller_identity()['Account']}:agent/{args.agent_id or args.agent_name}"
    
    try:
        response = client.create_registry_record(
            registryName=args.registry_name,
            recordId=record_id,
            description=f"{args.description} — Governed by RWWHW framework",
            resourceType='AGENT',
            resourceUri=resource_uri,
            metadata=metadata,
            tags={
                'RWWHW': 'true',
                'RiskClassification': args.risk_classification
            }
        )
        
        print(f"\n✓ Agent registered successfully")
        print(f"  Registry: {args.registry_name}")
        print(f"  Record ID: {record_id}")
        print(f"  ARN: {response['record']['recordArn']}")
        
        return response['record']
        
    except ClientError as e:
        if 'ConflictException' in str(e):
            print(f"⚠ Agent '{record_id}' already exists. Updating...")
            response = client.update_registry_record(
                registryName=args.registry_name,
                recordId=record_id,
                description=f"{args.description} — Governed by RWWHW framework",
                metadata=metadata
            )
            print(f"✓ Agent updated: {response['record']['recordArn']}")
            return response['record']
        raise


def verify_agent_in_registry(registry_name: str, record_id: str):
    """Verify agent was registered and show details."""
    client = boto3.client('bedrock-agentcore')
    
    try:
        response = client.get_registry_record(
            registryName=registry_name,
            recordId=record_id
        )
        
        record = response['record']
        metadata = record.get('metadata', {})
        
        print(f"\n{'='*60}")
        print(f"RWWHW AGENT REGISTRY VERIFICATION")
        print(f"{'='*60}")
        print(f"\n📋 Agent: {metadata.get('agentName', 'N/A')}")
        print(f"   Version: {metadata.get('version', 'N/A')}")
        print(f"   Status: {record.get('status', 'N/A')}")
        print(f"\n👤 Ownership (RWWHW #2: WHO)")
        print(f"   Technical Owner: {metadata.get('technicalOwner', 'N/A')}")
        print(f"   Business Owner: {metadata.get('businessOwner', 'N/A')}")
        print(f"   Risk Owner: {metadata.get('riskOwner', 'N/A')}")
        print(f"\n🛡️ Guardrails")
        print(f"   Guardrail ID: {metadata.get('guardrailId', 'N/A')}")
        print(f"   Risk Classification: {metadata.get('riskClassification', 'N/A')}")
        print(f"\n📁 Evidence Retention")
        print(f"   Days: {metadata.get('retentionDays', 'N/A')}")
        print(f"   S3 Bucket: Will be created by RWWHW deployment")
        print(f"\n✓ Agent ready for RWWHW governance monitoring")
        print(f"{'='*60}")
        
    except ClientError as e:
        print(f"✗ Verification failed: {e}")
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(
        description='Register Bedrock Agent with RWWHW Governance Registry'
    )
    
    # Required
    parser.add_argument('--agent-name', required=True, help='Agent name')
    parser.add_argument('--technical-owner', required=True, help='Technical owner email')
    parser.add_argument('--business-owner', required=True, help='Business owner email')
    parser.add_argument('--risk-owner', required=True, help='Risk owner (CRO) email')
    
    # Optional with defaults
    parser.add_argument('--registry-name', default='rwwhw-ai-governance', 
                        help='Bedrock Agent Registry name')
    parser.add_argument('--version', default='1', help='Agent version')
    parser.add_argument('--agent-id', help='Bedrock Agent ID (if different from name)')
    parser.add_argument('--guardrail-id', help='Bedrock Guardrail ID')
    parser.add_argument('--guardrail-version', default='DRAFT', help='Guardrail version')
    parser.add_argument('--risk-classification', default='MEDIUM',
                        choices=['LOW', 'MEDIUM', 'HIGH', 'CRITICAL'],
                        help='Risk classification')
    parser.add_argument('--description', default='AI Agent with RWWHW governance',
                        help='Agent description')
    parser.add_argument('--business-unit', default='default', help='Business unit')
    parser.add_argument('--approval-workflow', default='standard',
                        help='Approval workflow name')
    parser.add_argument('--retention-days', type=int, default=2555,
                        help='Evidence retention in days (default: 7 years)')
    parser.add_argument('--region', help='AWS region (defaults to AWS profile)')
    
    args = parser.parse_args()
    
    print(f"\n{'='*60}")
    print(f"RWWHW AI Governance — Agent Registration")
    print(f"{'='*60}")
    print(f"\nAgent: {args.agent_name}")
    print(f"Registry: {args.registry_name}")
    print(f"Region: {args.region or boto3.session.Session().region_name}")
    
    # Step 1: Get or create registry
    print(f"\n[1/3] Setting up Bedrock Agent Registry...")
    registry_arn = get_or_create_registry(args.registry_name, args.region)
    
    # Step 2: Register agent
    print(f"\n[2/3] Registering agent with governance metadata...")
    record = register_agent(args, registry_arn)
    
    # Step 3: Verify
    print(f"\n[3/3] Verifying registration...")
    record_id = f"{args.agent_name}-v{args.version}"
    verify_agent_in_registry(args.registry_name, record_id)
    
    print(f"\n✓ Registration complete!")
    print(f"\nNext steps:")
    print(f"  1. Deploy RWWHW governance layer: terraform apply")
    print(f"  2. Enable AgentCore Memory on your agent")
    print(f"  3. Dashboard: https://console.aws.amazon.com/cloudwatch/home#dashboards:name={args.registry_name}-governance")


if __name__ == '__main__':
    main()
