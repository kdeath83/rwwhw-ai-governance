import * as cdk from 'aws-cdk-lib';
import { RwwhwAiGovernanceStack } from '../lib/rwwhw-stack';

const app = new cdk.App();

new RwwhwAiGovernanceStack(app, 'RwwhwAiGovernanceStack', {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION || 'ap-southeast-2',
  },
  description: 'RWWHW AI Governance Framework - Answer 4 Questions in 30 Seconds',
  tags: {
    Framework: 'RWWHW',
    Purpose: 'AI-Governance',
    Compliance: 'APRA-Aligned',
  },
});
