import * as cdk from 'aws-cdk-lib';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as stepfunctions from 'aws-cdk-lib/aws-stepfunctions';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as sns from 'aws-cdk-lib/aws-sns';
import { Construct } from 'constructs';

export class RwwhwAiGovernanceStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    const projectName = 'rwwhw-ai-governance';
    const environment = props?.env?.region || 'ap-southeast-2';

    // RWWHW #2: Who - Agent Registry
    const agentRegistry = new dynamodb.Table(this, 'AgentRegistry', {
      tableName: `${projectName}-agent-registry`,
      partitionKey: { name: 'agent_id', type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
    });

    agentRegistry.addGlobalSecondaryIndex({
      indexName: 'RiskClassificationIndex',
      partitionKey: { name: 'risk_classification', type: dynamodb.AttributeType.STRING },
    });

    // RWWHW #1: What - Session Memory
    const sessionMemory = new dynamodb.Table(this, 'SessionMemory', {
      tableName: `${projectName}-session-memory`,
      partitionKey: { name: 'session_id', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'timestamp', type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
    });

    sessionMemory.addGlobalSecondaryIndex({
      indexName: 'AgentIdIndex',
      partitionKey: { name: 'agent_id', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'timestamp', type: dynamodb.AttributeType.STRING },
    });

    // RWWHW #4: Evidence - S3 Bucket with Object Lock
    const evidenceBucket = new s3.Bucket(this, 'EvidenceBucket', {
      bucketName: `${projectName}-evidence-${cdk.Stack.of(this).account}`,
      versioned: true,
      objectLockEnabled: true,
      objectLockDefaultRetention: s3.ObjectLockRetention.compliance(cdk.Duration.days(2555)),
    });

    // RWWHW #3: How - Circuit Breaker Lambda
    const circuitBreakerLambda = new lambda.Function(this, 'CircuitBreaker', {
      functionName: `${projectName}-circuit-breaker`,
      runtime: lambda.Runtime.PYTHON_3_11,
      handler: 'index.handler',
      code: lambda.Code.fromAsset('lambda/circuit_breaker'),
      timeout: cdk.Duration.seconds(30),
      environment: {
        ERROR_THRESHOLD: '0.1',
        LATENCY_THRESHOLD: '3000',
        NOTIFICATION_TOPIC: 'rwwhw-incident-alerts',
      },
    });

    // RWWHW #4: Evidence Generator Lambda
    const evidenceGeneratorLambda = new lambda.Function(this, 'EvidenceGenerator', {
      functionName: `${projectName}-evidence-generator`,
      runtime: lambda.Runtime.PYTHON_3_11,
      handler: 'index.handler',
      code: lambda.Code.fromAsset('lambda/evidence_generator'),
      timeout: cdk.Duration.seconds(60),
      environment: {
        EVIDENCE_BUCKET: evidenceBucket.bucketName,
        AUDIT_TABLE: sessionMemory.tableName,
      },
    });

    // Grant permissions
    evidenceBucket.grantReadWrite(evidenceGeneratorLambda);
    sessionMemory.grantReadData(evidenceGeneratorLambda);
    agentRegistry.grantReadData(evidenceGeneratorLambda);

    // RWWHW #3: How - SNS Topics
    const incidentAlerts = new sns.Topic(this, 'IncidentAlerts', {
      topicName: `${projectName}-incident-alerts`,
    });

    const croAlerts = new sns.Topic(this, 'CROAlerts', {
      topicName: `${projectName}-cro-alerts`,
    });

    // RWWHW #3: How - Step Functions for Human Review
    const humanReviewWorkflow = new stepfunctions.StateMachine(this, 'HumanReview', {
      stateMachineName: `${projectName}-human-review`,
      definition: this.createHumanReviewDefinition(incidentAlerts, croAlerts, evidenceGeneratorLambda),
      timeout: cdk.Duration.hours(24),
    });

    // RWWHW #4: What Evidence - Dashboard
    const dashboard = new cloudwatch.Dashboard(this, 'RwwhwDashboard', {
      dashboardName: `${projectName}-governance`,
    });

    dashboard.addWidgets(
      new cloudwatch.TextWidget({
        markdown: '# RWWHW AI Governance Dashboard - Answer 4 Questions in 30 Seconds',
        width: 24,
      }),
      new cloudwatch.LogQueryWidget({
        title: 'RWWHW #1: What Was It Trying To Do?',
        logGroupNames: ['/aws/bedrock/agentcore/sessions'],
        queryString: "fields agent_goal, reasoning_chain | filter incident_flag = true | sort timestamp desc | limit 10",
        width: 6,
        height: 6,
      }),
      new cloudwatch.LogQueryWidget({
        title: 'RWWHW #2: Who Owned It, What Rule Failed?',
        logGroupNames: ['/aws/bedrock/guardrails'],
        queryString: "fields rule_failed, business_owner, risk_owner | sort timestamp desc | limit 10",
        width: 6,
        height: 6,
      }),
      new cloudwatch.LogQueryWidget({
        title: 'RWWHW #3: How We Stopped & Recovered',
        logGroupNames: ['/aws/bedrock/circuit-breakers'],
        queryString: "fields stop_mechanism, recovery_method, human_reviewer | sort timestamp desc | limit 10",
        width: 6,
        height: 6,
      }),
      new cloudwatch.GraphWidget({
        title: 'RWWHW #4: Evidence Integrity',
        left: [
          new cloudwatch.Metric({
            namespace: 'AWS/S3',
            metricName: 'ObjectLockRetention',
            dimensionsMap: { BucketName: evidenceBucket.bucketName },
          }),
        ],
        width: 6,
        height: 6,
      })
    );

    // Outputs
    new cdk.CfnOutput(this, 'EvidenceBucket', {
      value: evidenceBucket.bucketName,
      description: 'S3 bucket for RWWHW evidence (7-year retention)',
    });

    new cdk.CfnOutput(this, 'AgentRegistryTable', {
      value: agentRegistry.tableName,
      description: 'DynamoDB table for agent ownership (Who)',
    });

    new cdk.CfnOutput(this, 'DashboardUrl', {
      value: `https://${environment}.console.aws.amazon.com/cloudwatch/home?region=${environment}#dashboards:name=${dashboard.dashboardName}`,
      description: 'CloudWatch Dashboard URL for 30-second incident response',
    });
  }

  private createHumanReviewDefinition(
    incidentAlerts: sns.Topic,
    croAlerts: sns.Topic,
    evidenceGenerator: lambda.Function
  ): stepfunctions.IChainable {
    const { Choice, Condition, Fail, Succeed, Task } = stepfunctions;
    const { LambdaInvoke, SnsPublish } = stepfunctions_tasks;

    const assessSeverity = new LambdaInvoke(this, 'AssessSeverity', {
      lambdaFunction: evidenceGenerator,
    });

    const routeBySeverity = new Choice(this, 'RouteBySeverity');

    const immediateEscalation = new SnsPublish(this, 'ImmediateEscalation', {
      topic: incidentAlerts,
      message: stepfunctions.TaskInput.fromObject({
        alert_type: 'CRITICAL',
        message: 'AI incident requires immediate attention',
      }),
    });

    const croReview = new SnsPublish(this, 'CROReview', {
      topic: croAlerts,
      message: stepfunctions.TaskInput.fromObject({
        alert_type: 'HIGH',
        message: 'AI incident requires CRO review',
      }),
    });

    const generateEvidence = new LambdaInvoke(this, 'GenerateEvidence', {
      lambdaFunction: evidenceGenerator,
    });

    const definition = assessSeverity
      .next(routeBySeverity
        .when(Condition.stringEquals('$.severity', 'CRITICAL'), immediateEscalation.next(generateEvidence))
        .when(Condition.stringEquals('$.severity', 'HIGH'), croReview.next(generateEvidence))
        .otherwise(generateEvidence)
      );

    return definition;
  }
}
