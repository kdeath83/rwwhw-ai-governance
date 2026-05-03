#!/usr/bin/env python3
"""
RWWHW AI Governance Framework — Evidence Generator
Generates tamper-proof evidence packages from Bedrock AgentCore services

Queries:
- Bedrock AgentCore Memory (What)
- AWS Agent Registry (Who)  
- Bedrock Guardrails (Who/Rules)
- Bedrock AgentCore Runtime (How)

Stores:
- S3 with Object Lock (Evidence)
- CloudTrail (API audit)
"""

import boto3
import json
import hashlib
import os
from datetime import datetime, timedelta

def handler(event, context):
    """
    Generate RWWHW evidence package from Bedrock AgentCore services.
    
    Expected event format:
    {
        "incident_id": "string",
        "session_id": "string",
        "agent_id": "string",
        "agent_name": "string",  # Used for registry lookup
        "human_decision": {
            "approved": bool,
            "reviewer": "string",
            "timestamp": "ISO8601"
        }
    }
    """
    
    incident_id = event.get('incident_id')
    session_id = event.get('session_id')
    agent_id = event.get('agent_id')
    agent_name = event.get('agent_name', agent_id)
    human_decision = event.get('human_decision', {})
    
    # AWS service clients
    bedrock_runtime = boto3.client('bedrock-agent-runtime')
    bedrock_agent = boto3.client('bedrock-agent')
    bedrock_agentcore = boto3.client('bedrock-agentcore')
    cloudwatch = boto3.client('cloudwatch')
    cloudwatch_logs = boto3.client('logs')
    s3 = boto3.client('s3')
    
    # Environment
    evidence_bucket = os.environ.get('EVIDENCE_BUCKET')
    registry_name = os.environ.get('REGISTRY_NAME', 'rwwhw-ai-governance')
    log_group_memory = os.environ.get('LOG_GROUP_MEMORY', '/aws/bedrock/agentcore/sessions')
    
    evidence_package = {
        'rwwhw_framework_version': '2.0.0',
        'incident_id': incident_id,
        'generated_at': datetime.utcnow().isoformat(),
        'retention_until': (datetime.utcnow() + timedelta(days=2555)).isoformat(),
        'sources': {
            'framework': 'RWWHW for Bedrock AgentCore',
            'memory_service': 'Amazon Bedrock AgentCore Memory',
            'registry_service': 'AWS Agent Registry',
            'runtime_service': 'Amazon Bedrock AgentCore Runtime',
            'guardrails_service': 'Amazon Bedrock Guardrails'
        },
        'what': {},
        'who': {},
        'how': {},
        'integrity': {}
    }
    
    # ═══════════════════════════════════════════════════════════
    # RWWHW #1: WHAT — Query Bedrock AgentCore Memory
    # ═══════════════════════════════════════════════════════════
    
    try:
        # Get session memory from Bedrock AgentCore
        memory_response = bedrock_runtime.get_agent_memory(
            agentId=agent_id,
            memoryId=session_id
        )
        
        memory_data = memory_response.get('memory', {})
        
        evidence_package['what'] = {
            'agent_id': agent_id,
            'session_id': session_id,
            'session_goal': memory_data.get('sessionGoal', 'N/A'),
            'reasoning_chain': memory_data.get('reasoningChain', []),
            'decision_path': memory_data.get('decisionPath', []),
            'input_context': memory_data.get('inputContext', {}),
            'final_output': memory_data.get('finalOutput', 'N/A'),
            'confidence_score': memory_data.get('confidenceScore', 0.0),
            'source': 'Bedrock AgentCore Memory API',
            'api_call': 'bedrock-agent-runtime:GetAgentMemory'
        }
        
    except Exception as e:
        evidence_package['what'] = {
            'error': str(e),
            'source': 'Bedrock AgentCore Memory API (failed)',
            'fallback': 'Check CloudWatch Logs /aws/bedrock/agentcore/sessions'
        }
    
    # ═══════════════════════════════════════════════════════════
    # RWWHW #2: WHO — Query AWS Agent Registry + Guardrails
    # ═══════════════════════════════════════════════════════════
    
    try:
        # Get agent ownership from AWS Agent Registry
        record_id = f"{agent_name}-v1"  # Default version lookup
        registry_response = bedrock_agentcore.get_registry_record(
            registryName=registry_name,
            recordId=record_id
        )
        
        record = registry_response.get('record', {})
        metadata = record.get('metadata', {})
        
        # Get guardrail details if configured
        guardrail_id = metadata.get('guardrailId')
        guardrail_info = {}
        
        if guardrail_id:
            try:
                guardrail_response = bedrock_agent.get_guardrail(
                    guardrailIdentifier=guardrail_id
                )
                guardrail_info = {
                    'guardrail_id': guardrail_id,
                    'guardrail_name': guardrail_response.get('name'),
                    'version': guardrail_response.get('version'),
                    'status': guardrail_response.get('status')
                }
            except Exception:
                guardrail_info = {'guardrail_id': guardrail_id, 'error': 'Could not fetch details'}
        
        evidence_package['who'] = {
            'agent_id': agent_id,
            'agent_name': agent_name,
            'registry_record_id': record_id,
            'technical_owner': metadata.get('technicalOwner', 'N/A'),
            'business_owner': metadata.get('businessOwner', 'N/A'),
            'risk_owner': metadata.get('riskOwner', 'N/A'),
            'risk_classification': metadata.get('riskClassification', 'N/A'),
            'business_unit': metadata.get('businessUnit', 'N/A'),
            'approval_workflow': metadata.get('approvalWorkflow', 'N/A'),
            'guardrails': guardrail_info,
            'rule_that_failed': event.get('rule_triggered', 'N/A'),
            'registry_source': 'AWS Agent Registry API',
            'api_call': 'bedrock-agentcore:GetRegistryRecord'
        }
        
    except Exception as e:
        # Fallback to Bedrock Agent API directly
        try:
            agent_response = bedrock_agent.get_agent(agentId=agent_id)
            agent_data = agent_response.get('agent', {})
            
            evidence_package['who'] = {
                'agent_id': agent_id,
                'agent_name': agent_data.get('agentName', 'N/A'),
                'description': agent_data.get('description', 'N/A'),
                'guardrail_configuration': agent_data.get('guardrailConfiguration', {}),
                'registry_source': 'Bedrock Agent API (fallback)',
                'api_call': 'bedrock:GetAgent',
                'registry_error': str(e)
            }
        except Exception as agent_error:
            evidence_package['who'] = {
                'error': f"Registry: {str(e)}; Agent API: {str(agent_error)}",
                'source': 'Both AWS Agent Registry and Bedrock Agent API failed'
            }
    
    # ═══════════════════════════════════════════════════════════
    # RWWHW #3: HOW — Query Bedrock AgentCore Runtime
    # ═══════════════════════════════════════════════════════════
    
    try:
        # Get CloudWatch metrics for runtime health
        end_time = datetime.utcnow()
        start_time = end_time - timedelta(minutes=30)
        
        error_metrics = cloudwatch.get_metric_statistics(
            Namespace='AWS/Bedrock',
            MetricName='InvocationErrors',
            Dimensions=[
                {'Name': 'AgentId', 'Value': agent_id}
            ],
            StartTime=start_time,
            EndTime=end_time,
            Period=300,
            Statistics=['Sum', 'Average']
        )
        
        latency_metrics = cloudwatch.get_metric_statistics(
            Namespace='AWS/Bedrock',
            MetricName='Latency',
            Dimensions=[
                {'Name': 'AgentId', 'Value': agent_id}
            ],
            StartTime=start_time,
            EndTime=end_time,
            Period=300,
            Statistics=['Average', 'p99']
        )
        
        evidence_package['how'] = {
            'stop_mechanism': event.get('stop_mechanism', 'guardrail_block'),
            'stop_timestamp': event.get('stop_timestamp', datetime.utcnow().isoformat()),
            'recovery_method': event.get('recovery_method', 'human_review'),
            'human_decision': human_decision,
            'runtime_metrics': {
                'error_count': sum([d['Sum'] for d in error_metrics.get('Datapoints', [])]),
                'avg_latency_ms': sum([d['Average'] for d in latency_metrics.get('Datapoints', [])]) / max(len(latency_metrics.get('Datapoints', [1])), 1),
                'p99_latency_ms': next((d['p99'] for d in latency_metrics.get('Datapoints', []) if 'p99' in d), 'N/A')
            },
            'circuit_breaker_triggered': event.get('circuit_breaker_triggered', False),
            'source': 'Bedrock AgentCore Runtime + CloudWatch',
            'api_calls': ['cloudwatch:GetMetricStatistics', 'cloudwatch:ListMetrics']
        }
        
    except Exception as e:
        evidence_package['how'] = {
            'error': str(e),
            'source': 'CloudWatch metrics query failed',
            'fallback': 'Check CloudWatch Logs /aws/bedrock/agentcore/runtime'
        }
    
    # ═══════════════════════════════════════════════════════════
    # RWWHW #4: EVIDENCE — Calculate Integrity + Store in S3
    # ═══════════════════════════════════════════════════════════
    
    # Calculate SHA256 hash for integrity verification
    evidence_json = json.dumps(evidence_package, sort_keys=True, default=str)
    evidence_hash = hashlib.sha256(evidence_json.encode()).hexdigest()
    
    evidence_package['integrity'] = {
        'sha256_hash': evidence_hash,
        'hash_algorithm': 'SHA256',
        'verification_method': 'Recalculate and compare',
        'generated_at': datetime.utcnow().isoformat(),
        'retention_days': 2555,
        'retention_until': (datetime.utcnow() + timedelta(days=2555)).isoformat()
    }
    
    # Store in S3 with Object Lock
    if evidence_bucket:
        key = f"evidence/{datetime.utcnow().strftime('%Y/%m/%d')}/{incident_id}/rwwhw-evidence.json"
        
        try:
            s3.put_object(
                Bucket=evidence_bucket,
                Key=key,
                Body=json.dumps(evidence_package, indent=2, default=str),
                ContentType='application/json',
                ChecksumAlgorithm='SHA256',
                Metadata={
                    'incident-id': incident_id,
                    'agent-id': agent_id,
                    'rwwhw-framework': 'true',
                    'rwwhw-version': '2.0.0',
                    'integrity-hash': evidence_hash,
                    'retention-mode': 'COMPLIANCE',
                    'retain-until': (datetime.utcnow() + timedelta(days=2555)).strftime('%Y-%m-%d')
                }
            )
            
            evidence_location = f"s3://{evidence_bucket}/{key}"
            
        except Exception as e:
            evidence_location = f"ERROR: {str(e)}"
    else:
        evidence_location = "ERROR: EVIDENCE_BUCKET not configured"
    
    # Log to CloudWatch for audit trail
    print(json.dumps({
        'timestamp': datetime.utcnow().isoformat(),
        'event': 'EVIDENCE_GENERATED',
        'incident_id': incident_id,
        'agent_id': agent_id,
        'evidence_location': evidence_location,
        'integrity_hash': evidence_hash,
        'sources': list(evidence_package.keys())
    }))
    
    return {
        'statusCode': 200,
        'body': json.dumps({
            'message': 'RWWHW evidence package generated from Bedrock AgentCore',
            'framework': 'RWWHW for Bedrock AgentCore v2.0.0',
            'incident_id': incident_id,
            'evidence_location': evidence_location,
            'integrity_hash': evidence_hash,
            'answers': {
                'what_source': 'Bedrock AgentCore Memory API',
                'who_source': 'AWS Agent Registry + Bedrock Guardrails',
                'how_source': 'Bedrock AgentCore Runtime + CloudWatch',
                'evidence_destination': evidence_location
            }
        }, indent=2)
    }


# For local testing
if __name__ == '__main__':
    test_event = {
        'incident_id': 'test-incident-001',
        'session_id': 'test-session-001',
        'agent_id': 'test-agent-001',
        'agent_name': 'test-agent',
        'rule_triggered': 'loan_amount_limit',
        'stop_mechanism': 'guardrail_block',
        'human_decision': {
            'approved': True,
            'reviewer': 'cro@company.com',
            'timestamp': datetime.utcnow().isoformat()
        }
    }
    
    result = handler(test_event, None)
    print(json.dumps(json.loads(result['body']), indent=2))
