#!/bin/bash

# This script runs on the runner host to authenticate to ACR
# using credentials stored in AWS Secrets Manager.

echo "--- Starting ACR Authentication Hook ---"

# Source environment variables from runner.env
if [ -f "/opt/runner.env" ]; then
    source /opt/runner.env
    echo "Loaded variables from /opt/runner.env"
else
    echo "Error: /opt/runner.env not found"
    exit 1
fi

# Validate required environment variables
if [ -z "$ROLE_ARN" ] || [ -z "$AWS_REGION" ] || [ -z "$SECRET_ID" ] || [ -z "$ACR_REGISTRY" ]; then
    echo "Error: Required environment variables (ROLE_ARN, AWS_REGION, SECRET_ID, ACR_REGISTRY) not set"
    exit 1
fi

# ==========================================================
# Part 1: Authenticate to AWS via OIDC
# ==========================================================
echo "Requesting OIDC token from GitHub..."
echo $ACTIONS_ID_TOKEN_REQUEST_TOKEN
echo $ACTIONS_ID_TOKEN_REQUEST_URL

OIDC_TOKEN=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=sts.amazonaws.com" | jq -r '.value')

if [ -z "$OIDC_TOKEN" ]; then
  echo "Error: Failed to get OIDC token."
fi

echo "Assuming IAM Role..."
AWS_CREDS=$(aws sts assume-role-with-web-identity \
  --role-arn "$ROLE_ARN" \
  --role-session-name "GitHubActions-ACR-Hook" \
  --web-identity-token "$OIDC_TOKEN" \
  --duration-seconds 900 \
  --region "$AWS_REGION" \
  --output json)

export AWS_ACCESS_KEY_ID=$(echo "$AWS_CREDS" | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo "$AWS_CREDS" | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo "$AWS_CREDS" | jq -r '.Credentials.SessionToken')

if [ -z "$AWS_ACCESS_KEY_ID" ]; then
  echo "Error: Failed to assume IAM Role and get AWS credentials." >&2
  exit 1
fi
 
# ==========================================================
# Part 2: Fetch ACR Credentials from Secrets Manager
# ==========================================================
echo "Fetching ACR credentials from AWS Secrets Manager..."
ACR_SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ID" --query SecretString --output text --region "$AWS_REGION")

ACR_USERNAME=$(echo "$ACR_SECRET_JSON" | jq -r .katiem0_actions_username)
ACR_PASSWORD=$(echo "$ACR_SECRET_JSON" | jq -r .katiem0_actions_secret)

if [ -z "$ACR_USERNAME" ] || [ -z "$ACR_PASSWORD" ]; then
  echo "Error: Could not parse username or password from secret." >&2
  exit 1
fi

# ==========================================================
# Part 3: Log in to Azure Container Registry
# ==========================================================
echo "Logging into $ACR_REGISTRY..."
echo "$ACR_PASSWORD" | docker login "$ACR_REGISTRY" --username "$ACR_USERNAME" --password-stdin

echo "--- ACR Authentication Hook Finished Successfully ---"