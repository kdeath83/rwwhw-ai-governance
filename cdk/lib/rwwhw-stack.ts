import * as cdk from 'aws-cdk-lib';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as stepfunctions from 'aws-cdk-lib/aws-stepfunctions';
import * as stepfunctions_tasks from 'aws-cdk-lib/aws-stepfunctions-tasks';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as sns from 'aws-cdk-lib/aws-sns';
import * as events from 'aws-cdk-lib/aws-events';
import * as events_targets from 'aws-cdk-lib/aws-events-targets';
import { Construct } from 'constructs';

/**
 * RWWHW AI Governance Stack for Amazon Bedrock AgentCore
 * 
 * This stack deploys the GOVERNANCE LAYER on top of AWS Bedrock AgentCore:
 * - Uses AWS Agent Registry for agent ownership (Who)
 * - Uses Bedrock AgentCore Memory for session traces (What)
 * - Uses Bedrock AgentCore Runtime for monitoring (How)
 * - Uses S3 Object Lock for evidence (What Evidence)
 */

export class RwwhwAiGovernanceStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    const projectName = 'rwwhw-ai-governance';
    const environment = props?.env?.region || 'ap-southeast-2';

    // ═══════════════════════════════════════════════════════════
    // S3 Bucket for Evidence (7-year Object Lock retention)
    // ═══════════════════════════════════════════════════════════
    const evidenceBucket = new s3.Bucket(this, 'EvidenceBucket', {
      bucketName: `${projectName}-evidence-${cdk.Stack.of(this).account}`,
      versioned: true,
      objectLockEnabled: true,
      objectLockDefaultRetention: s3.ObjectLockRetention.compliance(cdk.Duration.days(2555)),
      removalPolicy: cdk.RemovalPolicy.RETAIN, // Keep even if stack deleted
    });

    // ═══════════════════════════════════════════════════════════
    // IAM Role for Lambda with Bedrock AgentCore permissions
    // ═══════════════════════════════════════════════════════════
    const lambdaRole = new iam.Role(this, 'LambdaRole', {
      roleName: `${projectName}-lambda-role`,
      assumedBy: new iam.ServicePrincipal('lambda.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AWSLambdaBasicExecutionRole'),
      ],
    });

    // Bedrock AgentCore permissions
    lambdaRole.addToPolicy(new iam.PolicyStatement({
      sid: 'BedrockAgentCoreAccess',
      effect: iam.Effect.ALLOW,
      actions: [
        'bedrock:GetAgent',
        'bedrock:ListAgents',
        'bedrock:UpdateAgent',
        'bedrock:InvokeAgent',
        'bedrock-agentcore:GetRegistryRecord',
        'bedrock-agentcore:ListRegistryRecords',
        'bedrock-agentcore:SearchRegistry',
        'bedrock-agentcore-runtime:GetAgentMemory',
        'bedrock-agentcore-runtime:ListAgentMemory',
      ],
      resources: ['*'],
    }));

    // Guardrails permissions
    lambdaRole.addToPolicy(new iam.PolicyStatement({
      sid: 'BedrockGuardrailsAccess',
      effect: iam.Effect.ALLOW,
      actions: [
        'bedrock:GetGuardrail',
        'bedrock:ListGuardrails',
        'bedrock:GetGuardrailVersion',
      ],
      resources: ['*'],
    }));

    // CloudWatch permissions
    lambdaRole.addToPolicy(new iam.PolicyStatement({
      sid: 'CloudWatchMetrics',
      effect: iam.Effect.ALLOW,
      actions: [
        'cloudwatch:GetMetricStatistics',
        'cloudwatch:PutMetricData',
        'logs:CreateLogGroup',
        'logs:CreateLogStream',
        'logs:PutLogEvents',
        'logs:FilterLogEvents',
      ],
      resources: ['*'],
    }));

    // S3 evidence access
    evidenceBucket.grantReadWrite(lambdaRole);

    // ═══════════════════════════════════════════════════════════
    // CloudWatch Log Groups for Bedrock AgentCore Integration
    // ═══════════════════════════════════════════════════════════
    new cloudwatch.LogGroup(this, 'AgentCoreRuntimeLogs', {
      logGroupName: '/aws/bedrock/agentcore/runtime',
      retention: cdk.Duration.days(2555),
    });

    new cloudwatch.LogGroup(this, 'GuardrailsLogs', {
      logGroupName: '/aws/bedrock/guardrails',
      retention: cdk.Duration.days(2555),
    });

    new cloudwatch.LogGroup(this, 'AgentCoreMemoryLogs', {
      logGroupName: '/aws/bedrock/agentcore/sessions',
      retention: cdk.Duration.days(2555),
    });

    new cloudwatch.LogGroup(this, 'RwwhwAuditLogs', {
      logGroupName: '/aws/rwwhw/audit',
      retention: cdk.Duration.days(2555),
    });

    // ═══════════════════════════════════════════════════════════
    // SNS Topics for Alerts
    // ═══════════════════════════════════════════════════════════
    const incidentAlerts = new sns.Topic(this, 'IncidentAlerts', {
      topicName: `${projectName}-incident-alerts`,
    });

    const croAlerts = new sns.Topic(this, 'CROAlerts', {
      topicName: `${projectName}-cro-alerts`,
    });

    const riskTeamAlerts = new sns.Topic(this, 'RiskTeamAlerts', {
      topicName: `${projectName}-risk-team-alerts`,
    });

    // Allow Lambda to publish to SNS
    incidentAlerts.grantPublish(lambdaRole);
    croAlerts.grantPublish(lambdaRole);
    riskTeamAlerts.grantPublish(lambdaRole);

    // ═══════════════════════════════════════════════════════════
    // Lambda: Circuit Breaker for Bedrock AgentCore Runtime
    // ═══════════════════════════════════════════════════════════
    const circuitBreakerLambda = new lambda.Function(this, 'CircuitBreaker', {
      functionName: `${projectName}-circuit-breaker`,
      runtime: lambda.Runtime.PYTHON_3_11,
      handler: 'index.handler',
      code: lambda.Code.fromAsset('lambda/circuit_breaker'),
      timeout: cdk.Duration.seconds(30),
      role: lambdaRole,
      environment: {
        ERROR_THRESHOLD: '0.1',
        LATENCY_THRESHOLD: '3000',
        NOTIFICATION_TOPIC: incidentAlerts.topicArn,
        REGISTRY_NAME: projectName,
      },
    });

    // ═══════════════════════════════════════════════════════════
    // Lambda: Evidence Generator (queries Bedrock AgentCore APIs)
    // ═══════════════════════════════════════════════════════════
    const evidenceGeneratorLambda = new lambda.Function(this, 'EvidenceGenerator', {
      functionName: `${projectName}-evidence-generator`,
      runtime: lambda.Runtime.PYTHON_3_11,
      handler: 'index.handler',
      code: lambda.Code.fromAsset('lambda/evidence_generator'),
      timeout: cdk.Duration.seconds(60),
      role: lambdaRole,
      environment: {
        EVIDENCE_BUCKET: evidenceBucket.bucketName,
        REGISTRY_NAME: projectName,
        LOG_GROUP_MEMORY: '/aws/bedrock/agentcore/sessions',
        LOG_GROUP_GUARD: '/aws/bedrock/guardrails',
      },
    });

    // ═══════════════════════════════════════════════════════════
    // Step Functions: Human Review Workflow
    // ═══════════════════════════════════════════════════════════
    const stepFunctionsRole = new iam.Role(this, 'StepFunctionsRole', {
      roleName: `${projectName}-stepfunctions-role`,
      assumedBy: new iam.ServicePrincipal('states.amazonaws.com'),
    });

    stepFunctionsRole.addToPolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: ['lambda:InvokeFunction', 'sns:Publish'],
      resources: ['*'],
    }));

    const humanReviewWorkflow = new stepfunctions.StateMachine(this, 'HumanReview', {
      stateMachineName: `${projectName}-human-review`,
      definition: this.createHumanReviewDefinition(
        incidentAlerts,
        croAlerts,
        riskTeamAlerts,
        evidenceGeneratorLambda
      ),
      timeout: cdk.Duration.hours(24),
      role: stepFunctionsRole,
    });

    // ═══════════════════════════════════════════════════════════
    // EventBridge: Trigger on Bedrock Events
    // ═══════════════════════════════════════════════════════════
    const guardrailRule = new events.Rule(this, 'GuardrailBlockRule', {
      ruleName: `${projectName}-guardrail-block`,
      description: 'Trigger on Bedrock Guardrail blocks',
      eventPattern: {
        source: ['aws.bedrock'],
        detailType: ['Guardrail Intercepted'],
      },
    });
    guardrailRule.addTarget(new events_targets.SnsTopic(incidentAlerts));

    // ═══════════════════════════════════════════════════════════
    // CloudWatch Dashboard: 30-Second Answers
    // ═══════════════════════════════════════════════════════════
    const dashboard = new cloudwatch.Dashboard(this, 'RwwhwDashboard', {
      dashboardName: `${projectName}-governance`,
    });

    dashboard.addWidgets(
      new cloudwatch.TextWidget({
        markdown: '# RWWHW AI Governance for Bedrock AgentCore — Answer 4 Questions in 30 Seconds',
        width: 24,
      }),
      new cloudwatch.TextWidget({
        markdown: '**Bedrock AgentCore:** [Memory](https://console.aws.amazon.com/bedrock/memory) | [Registry](https://console.aws.amazon.com/bedrock/registry) | [Runtime](https://console.aws.amazon.com/bedrock/runtime) | [Guardrails](https://console.aws.amazon.com/bedrock/guardrails)',
        width: 24,
      }),
      // RWWHW #1: What — Bedrock AgentCore Memory
      new cloudwatch.LogQueryWidget({
        title: 'RWWHW #1: WHAT — Bedrock AgentCore Memory',
        logGroupNames: ['/aws/bedrock/agentcore/sessions'],
        queryString: 'fields @timestamp, agent_id, session_goal, reasoning_summary | filter strcontains(@message, "incident") or strcontains(@message, "guardrail_block") | sort @timestamp desc | limit 10',
        width: 6,
        height: 6,
      }),
      // RWWHW #2: Who — Bedrock Guardrails + Agent Registry
      new cloudwatch.LogQueryWidget({
        title: 'RWWHW #2: WHO — Guardrails & Registry',
        logGroupNames: ['/aws/bedrock/guardrails'],
        queryString: 'fields @timestamp, guardrail_id, rule_triggered, technical_owner, business_owner | filter action == "BLOCKED" | sort @timestamp desc | limit 10',
        width: 6,
        height: 6,
      }),
      // RWWHW #3: How — Bedrock AgentCore Runtime
      new cloudwatch.GraphWidget({
        title: 'RWWHW #3: HOW — AgentCore Runtime Health',
        width: 6,
        height: 6,
        left: [
          new cloudwatch.Metric({
            namespace: 'AWS/Bedrock',
            metricName: 'InvocationErrors',
            dimensionsMap: { AgentId: '*' },
            statistic: 'Sum',
            period: cdk.Duration.minutes(1),
          }),
        ],
        right: [
          new cloudwatch.Metric({
            namespace: 'AWS/Bedrock',
            metricName: 'Latency',
            dimensionsMap: { AgentId: '*' },
            statistic: 'Average',
            period: cdk.Duration.minutes(1),
          }),
        ],
      }),
      // RWWHW #4: Evidence — S3 Integrity
      new cloudwatch.GraphWidget({
        title: 'RWWHW #4: EVIDENCE — S3 Integrity',
        width: 6,
        height: 6,
        left: [
          new cloudwatch.Metric({
            namespace: 'AWS/S3',
            metricName: 'NumberOfObjects',
            dimensionsMap: { BucketName: evidenceBucket.bucketName },
            statistic: 'Average',
          }),
        ],
        right: [
          new cloudwatch.Metric({
            namespace: 'AWS/S3',
            metricName: 'BucketSizeBytes',
            dimensionsMap: { BucketName: evidenceBucket.bucketName },
            statistic: 'Average',
          }),
        ],
      }),
      // Evidence Generation Log
      new cloudwatch.LogQueryWidget({
        title: 'Evidence Packages Generated',
        logGroupNames: ['/aws/rwwhw/audit'],
        queryString: 'fields @timestamp, incident_id, agent_id, evidence_location, integrity_hash | filter strcontains(@message, "EVIDENCE_GENERATED") | sort @timestamp desc | limit 20',
        width: 24,
        height: 4,
      })
    );

    // ═══════════════════════════════════════════════════════════
    // Outputs
    // ═══════════════════════════════════════════════════════════
    new cdk.CfnOutput(this, 'EvidenceBucket', {
      value: evidenceBucket.bucketName,
      description: 'S3 bucket for RWWHW evidence (7-year Object Lock retention)',
    });

    new cdk.CfnOutput(this, 'DashboardUrl', {
      value: `https://${environment}.console.aws.amazon.com/cloudwatch/home?region=${environment}#dashboards:name=${dashboard.dashboardName}`,
      description: 'CloudWatch Dashboard URL for 30-second incident response',
    });

    new cdk.CfnOutput(this, 'StepFunctionsArn', {
      value: humanReviewWorkflow.stateMachineArn,
      description: 'Step Functions workflow ARN for human review',
    });

    new cdk.CfnOutput(this, 'CircuitBreakerLambda', {
      value: circuitBreakerLambda.functionName,
      description: 'Lambda function for Bedrock AgentCore circuit breaking',
    });

    new cdk.CfnOutput(this, 'RegistryName', {
      value: projectName,
      description: 'AWS Agent Registry name for agent registration',
    });
  }

  private createHumanReviewDefinition(
    incidentAlerts: sns.Topic,
    croAlerts: sns.Topic,
    riskTeamAlerts: sns.Topic,
    evidenceGenerator: lambda.Function
  ): stepfunctions.IChainable {
    const { Choice, Condition } = stepfunctions;
    const { LambdaInvoke, SnsPublish } = stepfunctions_tasks;

    const assessSeverity = new LambdaInvoke(this, 'AssessSeverity', {
      lambdaFunction: evidenceGenerator,
      payload: stepfunctions.TaskInput.fromObject({
        check_only: true,
      }),
    });

    const routeBySeverity = new Choice(this, 'RouteBySeverity');

    const immediateEscalation = new SnsPublish(this, 'ImmediateEscalation', {
      topic: incidentAlerts,
      message: stepfunctions.TaskInput.fromObject({
        alert_type: 'CRITICAL',
        message: 'Bedrock AgentCore incident requires immediate attention',
      }),
    });

    const croReview = new SnsPublish(this, 'CROReview', {
      topic: croAlerts,
      message: stepfunctions.TaskInput.fromObject({
        alert_type: 'HIGH',
        message: 'Bedrock AgentCore incident requires CRO review',
      }),
    });

    const riskTeamReview = new SnsPublish(this, 'RiskTeamReview', {
      topic: riskTeamAlerts,
      message: stepfunctions.TaskInput.fromObject({
        alert_type: 'MEDIUM',
        message: 'Bedrock AgentCore incident requires risk team review',
      }),
    });

    const generateEvidence = new LambdaInvoke(this, 'GenerateEvidence', {
      lambdaFunction: evidenceGenerator,
    });

    const definition = assessSeverity
      .next(routeBySeverity
        .when(Condition.stringEquals('$.Payload.severity', 'CRITICAL'), immediateEscalation.next(generateEvidence))
        .when(Condition.stringEquals('$.Payload.severity', 'HIGH'), croReview.next(generateEvidence))
        .when(Condition.stringEquals('$.Payload.severity', 'MEDIUM'), riskTeamReview.next(generateEvidence))
        .otherwise(generateEvidence)
      );

    return definition;
  }
}
