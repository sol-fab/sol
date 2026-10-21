#!/usr/bin/env bash
# AWS provisioner bootstrap by design; GCP reaches its provider through Workload Identity instead.
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${PROFILE:?Set PROFILE to an AWS CLI profile with IAM admin rights}"
USER_NAME="${USER_NAME:-sol-smoke-test-infra-provisioner}"
POLICY_NAME="${POLICY_NAME:-sol-smoke-test-infra}"

echo "==> Creating IAM policy ${POLICY_NAME}..."
POLICY_ARN="$(aws iam create-policy \
  --policy-name "$POLICY_NAME" \
  --policy-document file://smoke-test-iam-policy.json \
  --profile "$PROFILE" \
  --query 'Policy.Arn' --output text)"

echo "==> Creating IAM user ${USER_NAME}..."
aws iam create-user --user-name "$USER_NAME" --profile "$PROFILE" > /dev/null

echo "==> Attaching policy to ${USER_NAME}..."
aws iam attach-user-policy --user-name "$USER_NAME" --policy-arn "$POLICY_ARN" --profile "$PROFILE"

echo "==> Creating access key..."
creds="$(aws iam create-access-key --user-name "$USER_NAME" --profile "$PROFILE" \
  --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)"
read -r ACCESS_KEY_ID SECRET_ACCESS_KEY <<<"$creds"

CRED_FILE="${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}"
{
  echo ""
  echo "[${USER_NAME}]"
  echo "aws_access_key_id = ${ACCESS_KEY_ID}"
  echo "aws_secret_access_key = ${SECRET_ACCESS_KEY}"
} >> "$CRED_FILE"

echo "==> Wrote profile [${USER_NAME}] to ${CRED_FILE}."
echo "==> Policy ARN: ${POLICY_ARN}"
echo "==> Use with: AWS_PROFILE=${USER_NAME} AWS_REGION=us-east-1 terraform ..."
