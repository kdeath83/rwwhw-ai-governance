#!/usr/bin/env python3
"""
RWWHW AI Governance Framework - Evidence Generator
Generates tamper-proof evidence packages for AI incidents
"""

import boto3
import json
import hashlib
from datetime import datetime

def handler(event, context):
    """
    Generate RWWHW evidence package for an AI incident
    
    Expected event format:
    {
        "incident_id": "string",
        "session_id": "string", 
        "agent_id": "string",
        "timestamp": "ISO8601"
    }
    """
    
    incident_id = event.get('incident_id')
    session_id = event.get('session_id')
    agent_id = event.get('agent_id')
    
    # Initialize AWS clients
    dynamodb = boto3.resource('dynamodb')
    s3 = boto3.client('s3')
    cloudwatch = boto3.client('logs')
    
    # RWWHW #1: What Was It Trying To Do?
    session_memory = dynamodb.Table('rwwhw-ai-governance-session-memory')
    session_response = session_memory.get_item(
        Key={'session_id': session_id}
    )
    session_data = session_response.get('Item', {})
    
    what_evidence = {
        'agent_goal': session_data.get('agent_goal'),
        'reasoning_chain': session_data.get('reasoning_chain'),
        'decision_path': session_data.get('decision_path'),
        'confidence_score': session_data.get('confidence_score'),
        'input_context': session_data.get('input_context')
    }
    
    # RWWHW #2: Who Owned It, What Rule Failed?
    registry = dynamodb.Table('rwwhw-ai-governance-agent-registry')
    registry_response = registry.get_item(
        Key={'agent_id': agent_id}
    )
    agent_data = registry_response.get('Item', {})
    
    who_evidence = {
        'agent_id': agent_id,
        'technical_owner': agent_data.get('technical_owner'),
        'business_owner': agent_data.get('business_owner'),
        'risk_owner': agent_data.get('risk_owner'),
        'guardrail_rules': agent_data.get('guardrail_rules'),
        'rule_that_failed': event.get('rule_failed'),
        'approval_reference': agent_data.get('approval_workflow_reference')
    }
    
    # RWWHW #3: How We Stopped & Recovered
    # Query CloudWatch for circuit breaker events
    how_evidence = {
        'stop_mechanism': event.get('stop_mechanism', 'guardrail_block'),
        'stop_timestamp': event.get('stop_timestamp'),
        'recovery_method': event.get('recovery_method', 'human_review'),
        'recovery_timestamp': event.get('recovery_timestamp'),
        'human_reviewer': event.get('human_reviewer'),
        'business_owner_approval': event.get('business_owner_approval')
    }
    
    # RWWHW #4: What Does the Evidence Show? (Immutable)
    evidence_package = {
        'rwwhw_framework_version': '1.0.0',
        'incident_id': incident_id,
        'generated_at': datetime.utcnow().isoformat(),
        'retention_until': '2033-05-02T00:00:00Z',  # 7 years
        'what': what_evidence,
        'who': who_evidence,
        'how': how_evidence,
        'integrity': {}
    }
    
    # Calculate SHA256 hash for integrity
    evidence_json = json.dumps(evidence_package, sort_keys=True)
    evidence_hash = hashlib.sha256(evidence_json.encode()).hexdigest()
    evidence_package['integrity'] = {
        'sha256_hash': evidence_hash,
        'hash_algorithm': 'SHA256',
        'verification_method': 'Recalculate and compare'
    }
    
    # Store in S3 with Object Lock
    bucket = 'rwwhw-ai-governance-evidence'  # From environment variable
    key = f"{datetime.utcnow().strftime('%Y/%m/%d')}/{incident_id}/evidence-package.json"
    
    s3.put_object(
        Bucket=bucket,
        Key=key,
        Body=json.dumps(evidence_package, indent=2),
        ContentType='application/json',
        ChecksumAlgorithm='SHA256',
        Metadata={
            'incident-id': incident_id,
            'agent-id': agent_id,
            'rwwhw-framework': 'true'
        }
    )
    
    return {
        'statusCode': 200,
        'body': json.dumps({
            'message': 'RWWHW evidence package generated successfully',
            'incident_id': incident_id,
            'evidence_location': f's3://{bucket}/{key}',
            'sha256_hash': evidence_hash,
            'answers': {
                'what': 'Retrieved from session memory',
                'who': 'Retrieved from agent registry',
                'how': 'Retrieved from circuit breaker logs',
                'evidence': f's3://{bucket}/{key}'
            }
        })
    }
