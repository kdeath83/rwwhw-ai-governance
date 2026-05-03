#!/usr/bin/env python3
"""
WWHW AI Governance Framework - Circuit Breaker
Monitors AI agents and stops them when anomalies detected
"""

import boto3
import json
from datetime import datetime

def handler(event, context):
    """
    Circuit breaker for AI agent runtime
    
    Monitors error rates, latency, and guardrail violations
    Triggers stop mechanism when thresholds exceeded
    """
    
    cloudwatch = boto3.client('cloudwatch')
    sns = boto3.client('sns')
    bedrock = boto3.client('bedrock')
    
    agent_id = event.get('agent_id')
    
    # Get metrics from CloudWatch
    response = cloudwatch.get_metric_statistics(
        Namespace='AWS/Bedrock',
        MetricName='InvocationErrors',
        Dimensions=[
            {'Name': 'AgentId', 'Value': agent_id}
        ],
        StartTime=datetime.utcnow() - 5,
        EndTime=datetime.utcnow(),
        Period=60,
        Statistics=['Average']
    )
    
    error_rate = response['Datapoints'][0]['Average'] if response['Datapoints'] else 0
    
    # Get latency metrics
    latency_response = cloudwatch.get_metric_statistics(
        Namespace='AWS/Bedrock',
        MetricName='Latency',
        Dimensions=[
            {'Name': 'AgentId', 'Value': agent_id}
        ],
        StartTime=datetime.utcnow() - 5,
        EndTime=datetime.utcnow(),
        Period=60,
        Statistics=['Average']
    )
    
    latency = latency_response['Datapoints'][0]['Average'] if latency_response['Datapoints'] else 0
    
    # Thresholds from environment
    error_threshold = float(0.1)  # 10%
    latency_threshold = float(3000)  # 3 seconds
    
    # Circuit breaker logic
    circuit_open = False
    stop_reason = None
    
    if error_rate > error_threshold:
        circuit_open = True
        stop_reason = f"error_rate_exceeded_threshold: {error_rate:.2f} > {error_threshold}"
    elif latency > latency_threshold:
        circuit_open = True
        stop_reason = f"latency_exceeded_threshold: {latency:.0f}ms > {latency_threshold}ms"
    
    if circuit_open:
        # Disable the agent endpoint
        try:
            bedrock.update_endpoint(
                EndpointName=agent_id,
                EndpointConfigName='DISABLED-CIRCUIT-OPEN'
            )
        except Exception as e:
            print(f"Failed to disable endpoint: {e}")
        
        # Send alert
        sns.publish(
            TopicArn='rwwhw-ai-governance-incident-alerts',
            Message=json.dumps({
                'alert_type': 'CIRCUIT_BREAKER',
                'agent_id': agent_id,
                'stop_reason': stop_reason,
                'error_rate': error_rate,
                'latency': latency,
                'timestamp': datetime.utcnow().isoformat(),
                'action': 'AGENT_DISABLED'
            }),
            Subject=f'CIRCUIT BREAKER: {agent_id} disabled'
        )
        
        return {
            'statusCode': 200,
            'body': json.dumps({
                'circuit_status': 'OPEN',
                'agent_id': agent_id,
                'stop_reason': stop_reason,
                'action': 'AGENT_DISABLED',
                'timestamp': datetime.utcnow().isoformat()
            })
        }
    
    return {
        'statusCode': 200,
        'body': json.dumps({
            'circuit_status': 'CLOSED',
            'agent_id': agent_id,
            'error_rate': error_rate,
            'latency': latency
        })
    }
