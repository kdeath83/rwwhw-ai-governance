#!/bin/bash
#
# RWWHW AI Governance Framework — One-Click Deploy Script
# Deploys the governance layer to AWS Bedrock AgentCore
#
# Usage:
#   ./deploy.sh [OPTIONS]
#
# Options:
#   --region REGION          AWS region (default: us-east-1)
#   --stack-name NAME        CloudFormation stack name (default: rwwhw-ai-governance)
#   --registry-name NAME     Agent Registry name (default: rwwhw-ai-governance)
#   --retention-days DAYS    Evidence retention (default: 2555 = 7 years)
#   --skip-check             Skip Bedrock AgentCore availability check
#   --help                   Show this help
#
# Examples:
#   ./deploy.sh                                    # Deploy with defaults
#   ./deploy.sh --region ap-southeast-2            # Deploy to Sydney
#   ./deploy.sh --stack-name my-governance         # Custom stack name
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
REGION="${REGION:-us-east-1}"
STACK_NAME="${STACK_NAME:-rwwhw-ai-governance}"
REGISTRY_NAME="${REGISTRY_NAME:-rwwhw-ai-governance}"
RETENTION_DAYS="${RETENTION_DAYS:-2555}"
SKIP_CHECK=false
TEMPLATE_FILE="cloudformation/rwwhw-template.yaml"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --region)
      REGION="$2"
      shift 2
      ;;
    --stack-name)
      STACK_NAME="$2"
      shift 2
      ;;
    --registry-name)
      REGISTRY_NAME="$2"
      shift 2
      ;;
    --retention-days)
      RETENTION_DAYS="$2"
      shift 2
      ;;
    --skip-check)
      SKIP_CHECK=true
      shift
      ;;
    --help)
      head -n 25 "$0" | tail -n 23
      exit 0
      ;;
    *)
      echo -e "${RED}Unknown option: $1${NC}"
      echo "Use --help for usage"
      exit 1
      ;;
  esac
done

print_header() {
  echo ""
  echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║      RWWHW AI Governance Framework — One-Click Deploy       ║${NC}"
  echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

print_step() {
  echo -e "${YELLOW}[$(date +%H:%M:%S)]${NC} $1"
}

print_success() {
  echo -e "${GREEN}✓${NC} $1"
}

print_error() {
  echo -e "${RED}✗${NC} $1"
}

print_info() {
  echo -e "${BLUE}ℹ${NC} $1"
}

check_prerequisites() {
  print_step "Checking prerequisites..."
  
  # Check AWS CLI
  if ! command -v aws &> /dev/null; then
    print_error "AWS CLI not found. Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    exit 1
  fi
  print_success "AWS CLI found"
  
  # Check AWS credentials
  if ! aws sts get-caller-identity &> /dev/null; then
    print_error "AWS credentials not configured. Run: aws configure"
    exit 1
  fi
  
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  print_success "AWS credentials valid (Account: $ACCOUNT_ID)"
  
  # Check Bedrock AgentCore availability
  if [ "$SKIP_CHECK" = false ]; then
    print_step "Checking Bedrock AgentCore availability in $REGION..."
    
    if ! aws bedrock-agentcore list-registries --region "$REGION" --max-items 1 &> /dev/null; then
      echo ""
      print_error "Bedrock AgentCore not available or not enabled in $REGION"
      echo ""
      print_info "To enable Bedrock AgentCore:"
      echo "  1. AWS Console → Amazon Bedrock → AgentCore → 'Get Started'"
      echo "  2. Or contact your AWS account team"
      echo ""
      print_info "Supported regions: us-east-1, us-west-2, eu-west-1, ap-southeast-2"
      echo ""
      echo -n "Continue anyway? [y/N]: "
      read -r response
      if [[ ! "$response" =~ ^[Yy]$ ]]; then
        exit 1
      fi
    else
      print_success "Bedrock AgentCore available in $REGION"
    fi
  fi
  
  # Check template file
  if [ ! -f "$TEMPLATE_FILE" ]; then
    print_error "CloudFormation template not found: $TEMPLATE_FILE"
    print_info "Make sure you're running from the repository root"
    exit 1
  fi
  
  print_success "All prerequisites met"
}

package_and_deploy() {
  print_step "Packaging Lambda functions..."
  
  # Create S3 bucket for deployment artifacts if needed
  BUCKET_NAME="rwwhw-deploy-$ACCOUNT_ID-$REGION"
  
  if ! aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$REGION" 2>/dev/null; then
    print_info "Creating deployment bucket: $BUCKET_NAME"
    aws s3 mb "s3://$BUCKET_NAME" --region "$REGION"
  fi
  
  # Package template
  print_step "Creating CloudFormation package..."
  
  aws cloudformation package \
    --template-file "$TEMPLATE_FILE" \
    --s3-bucket "$BUCKET_NAME" \
    --output-template-file packaged-template.yaml \
    --region "$REGION"
  
  print_success "Package created"
  
  # Deploy stack
  print_step "Deploying CloudFormation stack: $STACK_NAME..."
  
  aws cloudformation deploy \
    --template-file packaged-template.yaml \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
    --parameter-overrides \
      "RegistryName=$REGISTRY_NAME" \
      "RetentionDays=$RETENTION_DAYS" \
    --tags \
      "Framework=RWWHW" \
      "Service=BedrockAgentCore" \
      "ManagedBy=CloudFormation"
  
  print_success "Stack deployed successfully"
}

get_outputs() {
  print_step "Getting deployment outputs..."
  
  # Wait for stack to be fully ready
  aws cloudformation wait stack-complete --stack-name "$STACK_NAME" --region "$REGION" 2>/dev/null || true
  
  OUTPUTS=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query 'Stacks[0].Outputs' \
    --output table)
  
  echo ""
  echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}                    DEPLOYMENT COMPLETE                       ${NC}"
  echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
  echo ""
  echo "$OUTPUTS"
  echo ""
  
  # Extract key values
  EVIDENCE_BUCKET=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`EvidenceBucket`].OutputValue' \
    --output text)
  
  DASHBOARD_URL=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`DashboardUrl`].OutputValue' \
    --output text)
  
  echo -e "${BLUE}Next Steps:${NC}"
  echo ""
  echo "1. ${YELLOW}Register your agents:${NC}"
  echo "   python scripts/register_agent.py \\"
  echo "     --agent-name my-agent \\"
  echo "     --technical-owner 'team@company.com' \\"
  echo "     --business-owner 'business@company.com' \\"
  echo "     --risk-owner 'cro@company.com'"
  echo ""
  echo "2. ${YELLOW}View the dashboard:${NC}"
  echo "   $DASHBOARD_URL"
  echo ""
  echo "3. ${YELLOW}Test circuit breaker:${NC}"
  echo "   aws lambda invoke \\"
  echo "     --function-name ${STACK_NAME}-circuit-breaker \\"
  echo "     --payload '{\"agent_id\": \"your-agent-id\", \"check_only\": true}' \\"
  echo "     --region $REGION response.json"
  echo ""
  echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
  echo ""
}

print_summary() {
  echo ""
  echo -e "${BLUE}Configuration Summary:${NC}"
  echo "  Region:        $REGION"
  echo "  Stack Name:    $STACK_NAME"
  echo "  Registry Name: $REGISTRY_NAME"
  echo "  Retention:     $RETENTION_DAYS days (7 years)"
  echo ""
}

main() {
  print_header
  print_summary
  check_prerequisites
  package_and_deploy
  get_outputs
  
  print_success "RWWHW AI Governance Framework deployed!"
  echo ""
  echo -e "${BLUE}Documentation:${NC} https://github.com/kdeath83/rwwhw-ai-governance"
  echo ""
}

main "$@"
