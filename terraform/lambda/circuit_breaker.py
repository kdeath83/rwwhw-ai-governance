#!/usr/bin/env python3
"""
RWWHW AI Governance Framework — Circuit Breaker for Bedrock AgentCore
Monitors Bedrock AgentCore Runtime and disables agents when anomalies detected

Integration Points:
- CloudWatch Metrics (Bedrock AgentCore Runtime)
- Bedrock Agent API (disable/enable agents)
- AWS Agent Registry (ownership lookup for alerts)
- SNS (notifications to owners)
"""

import boto3
import json
import os
from datetime import datetime, timedelta

def handler(event, context):
    """
    Circuit breaker for Bedrock AgentCore Runtime.
    
    Monitors:
    - Bedrock AgentCore Runtime error rates
    - Latency spikes
    - Guardrail violations
    
    Actions:
    - Disables agent via Bedrock API
    - Sends alerts to technical/business/risk owners
    - Triggers Step Functions for human review
    
    Expected event:
    {
        "agent_id": "string",
        "agent_name": "string",  # For registry lookup
        "check_only": false,     # If true, don't disable, just report
        "severity_threshold": "MEDIUM"  # MEDIUM, HIGH, CRITICAL
    }
    """
    
    # AWS clients
    cloudwatch = boto3.client('cloudwatch')
    cloudwatch_logs = boto3.client('logs')
    sns = boto3.client('sns')
    bedrock_agent = boto3.client('bedrock-agent')
    bedrock_agentcore = boto3.client('bedrock-agentcore')
    
    # Environment config
    notification_topic = os.environ.get('NOTIFICATION_TOPIC')
    registry_name = os.environ.get('REGISTRY_NAME', 'rwwhw-ai-governance')
    
    # Event parameters
    agent_id = event.get('agent_id')
    agent_name = event.get('agent_name', agent_id)
    check_only = event.get('check_only', False)
    severity_threshold = event.get('severity_threshold', 'MEDIUM')
    
    # Thresholds from environment or event
    error_threshold = float(os.environ.get('ERROR_THRESHOLD', '0.1'))  # 10%
    latency_threshold = float(os.environ.get('LATENCY_THRESHOLD', '3000'))  # 3s
    
    if not agent_id:
        return {
            'statusCode': 400,
            'body': json.dumps({'error': 'agent_id required'})
        }
    
    end_time = datetime.utcnow()
    start_time = end_time - timedelta(minutes=5)
    
    # ═══════════════════════════════════════════════════════════
    # Query Bedrock AgentCore Runtime metrics
    # ═══════════════════════════════════════════════════════════
    
    metrics = {
        'error_rate': 0.0,
        'latency_avg': 0.0,
        'latency_p99': 0.0,
        'guardrail_blocks': 0,
        'invocation_count': 0
    }
    
    try:
        # Error metrics
        error_response = cloudwatch.get_metric_statistics(
            Namespace='AWS/Bedrock',
            MetricName='InvocationErrors',
            Dimensions=[
                {'Name': 'AgentId', 'Value': agent_id}
            ],
            StartTime=start_time,
            EndTime=end_time,
            Period=60,
            Statistics=['Sum', 'Average']
        )
        
        error_datapoints = error_response.get('Datapoints', [])
        if error_datapoints:
            metrics['error_rate'] = error_datapoints[0].get('Average', 0)
            metrics['invocation_count'] = sum([dp.get('Sum', 0) for dp in error_datapoints])
        
        # Latency metrics
        latency_response = cloudwatch.get_metric_statistics(
            Namespace='AWS/Bedrock',
            MetricName='Latency',
            Dimensions=[
                {'Name': 'AgentId', 'Value': agent_id}
            ],
            StartTime=start_time,
            EndTime=end_time,
            Period=60,
            Statistics=['Average', 'p99']
        )
        
        latency_datapoints = latency_response.get('Datapoints', [])
        if latency_datapoints:
            metrics['latency_avg'] = latency_datapoints[0].get('Average', 0)
            metrics['latency_p99'] = next((dp.get('p99') for dp in latency_datapoints if 'p99' in dp), 0)
        
    except Exception as e:
        print(f"CloudWatch metrics error: {e}")
    
    # ═══════════════════════════════════════════════════════════
    # Check Guardrail blocks from logs
    # ═══════════════════════════════════════════════════════════
    
    try:
        log_response = cloudwatch_logs.filter_log_events(
            logGroupName='/aws/bedrock/guardrails',
            startTime=int(start_time.timestamp() * 1000),
            endTime=int(end_time.timestamp() * 1000),
            filterPattern=f'{{ $.agent_id = "{agent_id}" && $.action = "BLOCKED" }}'
        )
        metrics['guardrail_blocks'] = len(log_response.get('events', []))
    except Exception as e:
        print(f"CloudWatch logs error: {e}")
    
    # ═══════════════════════════════════════════════════════════
    # Circuit breaker logic
    # ═══════════════════════════════════════════════════════════
    
    circuit_open = False
    stop_reason = None
    severity = None
    
    # Determine severity
    if metrics['error_rate'] > error_threshold * 2 or metrics['latency_p99'] > latency_threshold * 2:
        severity = 'CRITICAL'
        circuit_open = True
        stop_reason = f"critical_threshold_exceeded: errors={metrics['error_rate']:.2%}, latency_p99={metrics['latency_p99']:.0f}ms"
    elif metrics['error_rate'] > error_threshold or metrics['latency_avg'] > latency_threshold:
        severity = 'HIGH'
        circuit_open = True
        stop_reason = f"threshold_exceeded: errors={metrics['error_rate']:.2%}, latency={metrics['latency_avg']:.0f}ms"
    elif metrics['guardrail_blocks'] > 5:
        severity = 'HIGH'
        circuit_open = True
        stop_reason = f"guardrail_blocks_spike: {metrics['guardrail_blocks']} blocks in 5min"
    elif metrics['guardrail_blocks'] > 0:
        severity = 'MEDIUM'
        # Don't open circuit for isolated guardrail blocks
    
    # If check_only mode, just report without disabling
    if check_only:
        return {
            'statusCode': 200,
            'body': json.dumps({
                'circuit_status': 'OPEN' if circuit_open else 'CLOSED',
                'severity': severity,
                'agent_id': agent_id,
                'metrics': metrics,
                'stop_reason': stop_reason,
                'check_only': True,
                'timestamp': datetime.utcnow().isoformat()
            })
        }
    
    # ═══════════════════════════════════════════════════════════
    # Execute circuit breaker — Disable via Bedrock API
    # ═══════════════════════════════════════════════════════════
    
    if circuit_open:
        action_taken = None
        disable_error = None
        
        try:
            # Disable agent using Bedrock Agent API
            bedrock_agent.update_agent(
                agentId=agent_id,
                agentStatus='DISABLED'
            )
            action_taken = 'AGENT_DISABLED'
            print(f"✓ Disabled agent {agent_id} via Bedrock API")
            
        except Exception as e:
            disable_error = str(e)
            print(f"✗ Failed to disable agent: {e}")
            action_taken = 'DISABLE_FAILED'
        
        # ═══════════════════════════════════════════════════════
        # Lookup ownership from AWS Agent Registry for alerts
        # ═══════════════════════════════════════════════════════
        
        owners = {
            'technical': 'unknown',
            'business': 'unknown',
            'risk': 'unknown'
        }
        
        try:
            record_id = f"{agent_name}-v1"
            registry_response = bedrock_agentcore.get_registry_record(
                registryName=registry_name,
                recordId=record_id
            )
            
            metadata = registry_response.get('record', {}).get('metadata', {})
            owners['technical'] = metadata.get('technicalOwner', 'unknown')
            owners['business'] = metadata.get('businessOwner', 'unknown')
            owners['risk'] = metadata.get('riskOwner', 'unknown')
            
        except Exception as e:
            print(f"Registry lookup failed: {e}")
        
        # ═══════════════════════════════════════════════════════
        # Send alert to SNS
        # ═══════════════════════════════════════════════════════
        
        if notification_topic:
            try:
                alert_message = {
                    'alert_type': 'CIRCUIT_BREAKER',
                    'severity': severity,
                    'agent_id': agent_id,
                    'agent_name': agent_name,
                    'stop_reason': stop_reason,
                    'action_taken': action_taken,
                    'metrics': metrics,
                    'owners': owners,
                    'timestamp': datetime.utcnow().isoformat(),
                    'next_steps': [
                        f"Technical owner ({owners['technical']}) investigate",
                        f"Risk owner ({owners['risk']}) review if HIGH/CRITICAL",
                        'Use Step Functions workflow to approve recovery'
                    ]
                }
                
                sns.publish(
                    TopicArn=notification_topic,
                    Message=json.dumps(alert_message, indent=2),
                    Subject=f'[{severity}] CIRCUIT BREAKER: {agent_name} ({agent_id})'
                )
                
                print(f"✓ Alert sent to SNS: {notification_topic}")
                
            except Exception as e:
                print(f"SNS alert failed: {e}")
        
        # Log to CloudWatch for audit
        print(json.dumps({
            'timestamp': datetime.utcnow().isoformat(),
            'event': 'CIRCUIT_BREAKER_TRIGGERED',
            'agent_id': agent_id,
            'severity': severity,
            'stop_reason': stop_reason,
            'action': action_taken,
            'metrics': metrics,
            'owners': owners
        }))
        
        return {
            'statusCode': 200,
            'body': json.dumps({
                'circuit_status': 'OPEN',
                'severity': severity,
                'agent_id': agent_id,
                'stop_reason': stop_reason,
                'action_taken': action_taken,
                'disable_error': disable_error,
                'metrics': metrics,
                'owners': owners,
                'sources': {
                    'runtime_metrics': 'CloudWatch (Bedrock AgentCore)',
                    'guardrail_blocks': 'CloudWatch Logs (/aws/bedrock/guardrails)',
                    'ownership': f'AWS Agent Registry ({registry_name})',
                    'disable_api': 'Bedrock Agent API (UpdateAgent)'
                },
                'timestamp': datetime.utcnow().isoformat()
            }, indent=2)
        }
    
    # Circuit closed — normal operation
    return {
        'statusCode': 200,
        'body': json.dumps({
            'circuit_status': 'CLOSED',
            'agent_id': agent_id,
            'metrics': metrics,
            'checks': {
                'error_rate': f"{metrics['error_rate']:.2%} (threshold: {error_threshold:.0%})",
                'latency': f"{metrics['latency_avg']:.0f}ms avg, {metrics['latency_p99']:.0f}ms p99 (threshold: {latency_threshold:.0f}ms)",
                'guardrail_blocks': f"{metrics['guardrail_blocks']} in 5min"
            },
            'timestamp': datetime.utcnow().isoformat()
        })
    }


# For local testing
if __name__ == '__main__':
    test_event = {
        'agent_id': 'test-agent-001',
        'agent_name': 'test-agent',
        'check_only': True
    }
    
    result = handler(test_event, None)
    print(json.dumps(json.loads(result['body']), indent=2))
