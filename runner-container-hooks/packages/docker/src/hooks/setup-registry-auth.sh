#!/bin/bash
set -e

echo "--- ACR Authentication Hook Started ---"

# ==========================================================
# Configuration
# ==========================================================
TEMP_DOCKER_CONFIG=$(mktemp -d -t docker-config.XXXXXX)
chmod 700 "$TEMP_DOCKER_CONFIG"
trap "rm -rf $TEMP_DOCKER_CONFIG" EXIT

# Disable bash history and command echoing for security
set +o history
set +x

# ==========================================================
# Part 1: Authenticate to AWS via OIDC
# ==========================================================
echo "Requesting OIDC token from GitHub..."

OIDC_TOKEN=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=sts.amazonaws.com" 2>/dev/null | jq -r '.value')

if [ -z "$OIDC_TOKEN" ]; then
  echo "Error: Failed to get OIDC token." >&2
  exit 1
fi

echo "Assuming IAM Role..."
AWS_CREDS=$(aws sts assume-role-with-web-identity \
  --role-arn "$ROLE_ARN" \
  --role-session-name "GitHubActions-ACR-Hook" \
  --web-identity-token "$OIDC_TOKEN" \
  --duration-seconds 900 \
  --region "$AWS_REGION" \
  --output json 2>/dev/null)

# Clear the OIDC token from memory immediately
unset OIDC_TOKEN

if [ -z "$AWS_CREDS" ]; then
  echo "Error: Failed to assume IAM role." >&2
  exit 1
fi

export AWS_ACCESS_KEY_ID=$(echo "$AWS_CREDS" | jq -r '.Credentials.AccessKeyId' 2>/dev/null)
export AWS_SECRET_ACCESS_KEY=$(echo "$AWS_CREDS" | jq -r '.Credentials.SecretAccessKey' 2>/dev/null)
export AWS_SESSION_TOKEN=$(echo "$AWS_CREDS" | jq -r '.Credentials.SessionToken' 2>/dev/null)

# Clear the AWS credentials JSON from memory
unset AWS_CREDS

if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ] || [ -z "$AWS_SESSION_TOKEN" ]; then
  echo "Error: Could not parse AWS credentials." >&2
  exit 1
fi

# ==========================================================
# Part 2: Retrieve ACR credentials from AWS Secrets Manager
# ==========================================================
echo "Retrieving ACR credentials from AWS Secrets Manager..."
ACR_SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_ID" \
  --region "$AWS_REGION" \
  --query SecretString \
  --output text 2>/dev/null)

if [ -z "$ACR_SECRET_JSON" ]; then
  echo "Error: Failed to retrieve secret from AWS Secrets Manager." >&2
  exit 1
fi

ACR_USERNAME=$(echo "$ACR_SECRET_JSON" | jq -r '.registry_username' 2>/dev/null)
ACR_PASSWORD=$(echo "$ACR_SECRET_JSON" | jq -r '.registry_password' 2>/dev/null)

# Clear the secret JSON from memory immediately
unset ACR_SECRET_JSON

if [ -z "$ACR_USERNAME" ] || [ -z "$ACR_PASSWORD" ]; then
  echo "Error: Could not parse username or password from secret." >&2
  exit 1
fi

# ==========================================================
# Part 3: Log in to Azure Container Registry
# ==========================================================
echo "Logging into $ACR_REGISTRY..."
echo "$ACR_PASSWORD" | docker --config "$TEMP_DOCKER_CONFIG" login "$ACR_REGISTRY" --username "$ACR_USERNAME" --password-stdin 2>/dev/null

# Verify login was successful
if [ $? -ne 0 ]; then
  echo "Error: Docker login failed." >&2
  exit 1
fi

# Copy the auth config to the default location for the runner session
mkdir -p ~/.docker
cp "$TEMP_DOCKER_CONFIG/config.json" ~/.docker/config.json
chmod 600 ~/.docker/config.json

# Clear credentials from memory
unset ACR_USERNAME
unset ACR_PASSWORD
unset AWS_ACCESS_KEY_ID
unset AWS_SECRET_ACCESS_KEY
unset AWS_SESSION_TOKEN

echo "--- ACR Authentication Hook Finished Successfully ---"

# Re-enable history for subsequent commands (if needed)
set -o history