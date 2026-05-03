#!/usr/bin/env pwsh
<#
.SYNOPSIS
    RWWHW AI Governance Framework — One-Click Deploy Script (PowerShell)
    Deploys the governance layer to AWS Bedrock AgentCore

.DESCRIPTION
    This script automates the deployment of RWWHW AI Governance Framework
    using CloudFormation. It handles packaging, S3 bucket creation, and
    stack deployment.

.PARAMETER Region
    AWS region (default: us-east-1)

.PARAMETER StackName
    CloudFormation stack name (default: rwwhw-ai-governance)

.PARAMETER RegistryName
    Agent Registry name (default: rwwhw-ai-governance)

.PARAMETER RetentionDays
    Evidence retention in days (default: 2555 = 7 years)

.PARAMETER SkipCheck
    Skip Bedrock AgentCore availability check

.EXAMPLE
    .\deploy.ps1                                    # Deploy with defaults
    .\deploy.ps1 -Region ap-southeast-2            # Deploy to Sydney
    .\deploy.ps1 -StackName my-governance          # Custom stack name

.LINK
    https://github.com/kdeath83/rwwhw-ai-governance
#>

[CmdletBinding()]
param(
    [string]$Region = "us-east-1",
    [string]$StackName = "rwwhw-ai-governance",
    [string]$RegistryName = "rwwhw-ai-governance",
    [int]$RetentionDays = 2555,
    [switch]$SkipCheck
)

$ErrorActionPreference = "Stop"

# Colors
$Colors = @{
    Red = "`e[0;31m"
    Green = "`e[0;32m"
    Yellow = "`e[1;33m"
    Blue = "`e[0;34m"
    NC = "`e[0m"
}

function Write-Header {
    Write-Host ""
    Write-Host "$($Colors.Blue)╔════════════════════════════════════════════════════════════╗$($Colors.NC)"
    Write-Host "$($Colors.Blue)║      RWWHW AI Governance Framework — One-Click Deploy       ║$($Colors.NC)"
    Write-Host "$($Colors.Blue)╚════════════════════════════════════════════════════════════╝$($Colors.NC)"
    Write-Host ""
}

function Write-Step($Message) {
    $timestamp = Get-Date -Format "HH:mm:ss"
    Write-Host "$($Colors.Yellow)[$timestamp]$($Colors.NC) $Message"
}

function Write-Success($Message) {
    Write-Host "$($Colors.Green)✓$($Colors.NC) $Message"
}

function Write-Error($Message) {
    Write-Host "$($Colors.Red)✗$($Colors.NC) $Message"
}

function Write-Info($Message) {
    Write-Host "$($Colors.Blue)ℹ$($Colors.NC) $Message"
}

function Test-Prerequisites {
    Write-Step "Checking prerequisites..."
    
    # Check AWS CLI
    try {
        $awsVersion = aws --version 2>$null
        if ($LASTEXITCODE -ne 0) { throw "AWS CLI not found" }
        Write-Success "AWS CLI found: $awsVersion"
    }
    catch {
        Write-Error "AWS CLI not found. Install from: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
        exit 1
    }
    
    # Check AWS credentials
    try {
        $caller = aws sts get-caller-identity --output json | ConvertFrom-Json
        $script:AccountId = $caller.Account
        Write-Success "AWS credentials valid (Account: $AccountId)"
    }
    catch {
        Write-Error "AWS credentials not configured. Run: aws configure"
        exit 1
    }
    
    # Check Bedrock AgentCore availability
    if (-not $SkipCheck) {
        Write-Step "Checking Bedrock AgentCore availability in $Region..."
        
        try {
            aws bedrock-agentcore list-registries --region $Region --max-items 1 2>$null | Out-Null
            Write-Success "Bedrock AgentCore available in $Region"
        }
        catch {
            Write-Host ""
            Write-Error "Bedrock AgentCore not available or not enabled in $Region"
            Write-Host ""
            Write-Info "To enable Bedrock AgentCore:"
            Write-Host "  1. AWS Console → Amazon Bedrock → AgentCore → 'Get Started'"
            Write-Host "  2. Or contact your AWS account team"
            Write-Host ""
            Write-Info "Supported regions: us-east-1, us-west-2, eu-west-1, ap-southeast-2"
            Write-Host ""
            
            $response = Read-Host "Continue anyway? [y/N]"
            if ($response -notmatch '^[Yy]$') {
                exit 1
            }
        }
    }
    
    # Check template file
    $TemplateFile = "cloudformation/rwwhw-template.yaml"
    if (-not (Test-Path $TemplateFile)) {
        Write-Error "CloudFormation template not found: $TemplateFile"
        Write-Info "Make sure you're running from the repository root"
        exit 1
    }
    
    Write-Success "All prerequisites met"
}

function Deploy-Stack {
    Write-Step "Packaging Lambda functions..."
    
    # Create S3 bucket for deployment artifacts
    $BucketName = "rwwhw-deploy-$AccountId-$Region"
    
    try {
        aws s3api head-bucket --bucket $BucketName --region $Region 2>$null | Out-Null
    }
    catch {
        Write-Info "Creating deployment bucket: $BucketName"
        aws s3 mb "s3://$BucketName" --region $Region | Out-Null
    }
    
    # Package template
    Write-Step "Creating CloudFormation package..."
    
    aws cloudformation package `
        --template-file "cloudformation/rwwhw-template.yaml" `
        --s3-bucket $BucketName `
        --output-template-file packaged-template.yaml `
        --region $Region
    
    Write-Success "Package created"
    
    # Deploy stack
    Write-Step "Deploying CloudFormation stack: $StackName..."
    
    aws cloudformation deploy `
        --template-file packaged-template.yaml `
        --stack-name $StackName `
        --region $Region `
        --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM `
        --parameter-overrides "RegistryName=$RegistryName" "RetentionDays=$RetentionDays" `
        --tags "Framework=RWWHW" "Service=BedrockAgentCore" "ManagedBy=CloudFormation"
    
    Write-Success "Stack deployed successfully"
}

function Get-DeploymentOutputs {
    Write-Step "Getting deployment outputs..."
    
    # Wait for stack
    aws cloudformation wait stack-complete --stack-name $StackName --region $Region 2>$null
    
    $Outputs = aws cloudformation describe-stacks `
        --stack-name $StackName `
        --region $Region `
        --query 'Stacks[0].Outputs' `
        --output table
    
    Write-Host ""
    Write-Host "$($Colors.Green)════════════════════════════════════════════════════════════$($Colors.NC)"
    Write-Host "$($Colors.Green)                    DEPLOYMENT COMPLETE                       $($Colors.NC)"
    Write-Host "$($Colors.Green)════════════════════════════════════════════════════════════$($Colors.NC)"
    Write-Host ""
    Write-Host $Outputs
    Write-Host ""
    
    # Extract key values
    $EvidenceBucket = aws cloudformation describe-stacks `
        --stack-name $StackName `
        --region $Region `
        --query 'Stacks[0].Outputs[?OutputKey==`EvidenceBucket`].OutputValue' `
        --output text
    
    $DashboardUrl = aws cloudformation describe-stacks `
        --stack-name $StackName `
        --region $Region `
        --query 'Stacks[0].Outputs[?OutputKey==`DashboardUrl`].OutputValue' `
        --output text
    
    Write-Host "$($Colors.Blue)Next Steps:$($Colors.NC)"
    Write-Host ""
    Write-Host "1. $($Colors.Yellow)Register your agents:$($Colors.NC)"
    Write-Host "   python scripts\register_agent.py \`
    Write-Host "     --agent-name my-agent \`
    Write-Host "     --technical-owner 'team@company.com' \`
    Write-Host "     --business-owner 'business@company.com' \`
    Write-Host "     --risk-owner 'cro@company.com'"
    Write-Host ""
    Write-Host "2. $($Colors.Yellow)View the dashboard:$($Colors.NC)"
    Write-Host "   $DashboardUrl"
    Write-Host ""
    Write-Host "3. $($Colors.Yellow)Test circuit breaker:$($Colors.NC)"
    Write-Host "   aws lambda invoke \`
    Write-Host "     --function-name ${StackName}-circuit-breaker \`
    Write-Host "     --payload '{\"agent_id\": \"your-agent-id\", \"check_only\": true}' \`
    Write-Host "     --region $Region response.json"
    Write-Host ""
    Write-Host "$($Colors.Green)════════════════════════════════════════════════════════════$($Colors.NC)"
    Write-Host ""
}

function Write-Summary {
    Write-Host ""
    Write-Host "$($Colors.Blue)Configuration Summary:$($Colors.NC)"
    Write-Host "  Region:        $Region"
    Write-Host "  Stack Name:    $StackName"
    Write-Host "  Registry Name: $RegistryName"
    Write-Host "  Retention:     $RetentionDays days (7 years)"
    Write-Host ""
}

# Main execution
Write-Header
Write-Summary
Test-Prerequisites
Deploy-Stack
Get-DeploymentOutputs

Write-Success "RWWHW AI Governance Framework deployed!"
Write-Host ""
Write-Host "$($Colors.Blue)Documentation:$($Colors.NC) https://github.com/kdeath83/rwwhw-ai-governance"
Write-Host ""
