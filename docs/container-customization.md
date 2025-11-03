# Custom Container Image Workflow Documentation

This document explains the [`image-ubu24-customcontainer.yml`](.github/workflows/image-ubu24-customcontainer.yml) workflow and how the container registry authentication works through the [`setup-registry-auth.sh`](runner-container-hooks/packages/docker/src/hooks/setup-registry-auth.sh) script.

## Workflow Architecture

### Overview
The workflow builds a customized Ubuntu 24.04 runner image with:
- Docker pre-installed and configured
- Container hook system for registry authentication
- Pre/post-job scripts for security and workflow management
- Common development tools

### Key Workflow Steps

#### 1. Security and Environment Setup
```yaml
- name: Setup private key PEM file
  run: |
    echo "${{ secrets.GITHUB_APP_PRIVATE_KEY }}" | sudo tee /opt/pre-script-auth.pem
    sudo chmod 600 /opt/pre-script-auth.pem

- name: Setup environment vars file for runner
  run: |
    sudo cp "${{ github.workspace }}/runner.env" /opt/runner.env
    sudo chown runner:runner /opt/runner.env
    sudo chmod 600 /opt/runner.env
```

**Security Features:**
- Private key stored securely in `/opt/pre-script-auth.pem`
- Environment variables from `runner.env` copied with restricted permissions (600)
- Ownership set to `runner:runner` for proper access control

#### 2. Hook Scripts Installation
```yaml
- name: Add pre-script
  run: |
    sudo cp "${{ github.workspace }}/scripts/pre-script.sh" /opt/pre-script.sh
    sudo chmod +x /opt/pre-script.sh
    echo "ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/pre-script.sh" | sudo tee -a /etc/environment /root/actions-runner/.env

- name: Add post-script
  run: |
    sudo cp "${{ github.workspace }}/scripts/post-script.sh" /opt/post-script.sh
    sudo chmod +x /opt/post-script.sh
    echo "ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/opt/post-script.sh" | sudo tee -a /etc/environment /root/actions-runner/.env
```

**Hook System:**
- Pre-script runs before each job for security scanning
- Post-script runs after job completion for cleanup
- Hooks configured via environment variables

#### 3. Container Customizations
```yaml
- name: Add container customizations
  run: |
    sudo cp -r "${{ github.workspace }}/runner-container-hooks" /opt/runner-container-hooks
    sudo chown -R runner:runner /opt/runner-container-hooks
    cd /opt/runner-container-hooks/packages/hooklib
    npm install && npm run build
    cd ../docker
    npm install && npm run build
    echo "ACTIONS_RUNNER_CONTAINER_HOOKS=/opt/runner-container-hooks/packages/docker/dist/index.js" | sudo tee -a /etc/environment /root/actions-runner/.env
```

**Container Hook Features:**
- Docker container lifecycle management
- Registry authentication via OIDC
- Custom container initialization

## Registry Authentication Process

The authentication system uses a multi-layer approach:

### 1. OIDC Token Acquisition
```bash
OIDC_TOKEN=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=sts.amazonaws.com" | jq -r '.value')
```

### 2. AWS IAM Role Assumption
```bash
AWS_CREDS=$(aws sts assume-role-with-web-identity \
  --role-arn "$ROLE_ARN" \
  --role-session-name "GitHubActions-ACR-Hook" \
  --web-identity-token "$OIDC_TOKEN" \
  --duration-seconds 900 \
  --region "$AWS_REGION" \
  --output json)
```

### 3. Secrets Manager Retrieval
```bash
ACR_SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_ID" \
  --region "$AWS_REGION" \
  --query SecretString \
  --output text)
```

### 4. Docker Registry Login
```bash
echo "$ACR_PASSWORD" | docker --config "$TEMP_DOCKER_CONFIG" login "$ACR_REGISTRY" \
  --username "$ACR_USERNAME" --password-stdin
```

### Security Features

#### Credential Protection
1. **Temporary Configuration**: Uses isolated Docker config directory
   ```bash
   TEMP_DOCKER_CONFIG=$(mktemp -d -t docker-config.XXXXXX)
   chmod 700 "$TEMP_DOCKER_CONFIG"
   trap "rm -rf $TEMP_DOCKER_CONFIG" EXIT
   ```

2. **Secure Memory Management**: Immediately unsets sensitive variables after use
   ```bash
   # Clear the OIDC token from memory immediately
   unset OIDC_TOKEN
   
   # Clear the AWS credentials JSON from memory
   unset AWS_CREDS
   
   # Clear credentials from memory
   unset ACR_USERNAME
   unset ACR_PASSWORD
   ```

3. **No Command History**: Disables bash history during credential operations
   ```bash
   # Disable bash history and command echoing for security
   set +o history
   set +x
   ```

4. **Error Suppression**: Prevents credentials from appearing in error messages
   ```bash
   # All commands use 2>/dev/null to suppress error output
   ```

#### File Permissions
```bash
# Secure final Docker config
mkdir -p ~/.docker
cp "$TEMP_DOCKER_CONFIG/config.json" ~/.docker/config.json
chmod 600 ~/.docker/config.json
```

## Configuration Management

### Environment Variables (`runner.env.example`)
The workflow uses centralized configuration:

```bash
# GitHub App credentials for workflow security scanning
APP_ID="YOUR_APP_ID"
INSTALLATION_ID="YOUR_INSTALLATION_ID"
PRIVATE_KEY_PATH="/opt/pre-script-auth.pem"

# AWS IAM Role to assume for registry access
ROLE_ARN="arn:aws:iam::ACCOUNT_ID:role/YOUR_ROLE_NAME"
AWS_REGION="us-east-1"
SECRET_ID="YOUR_SECRET_ID"
ACR_REGISTRY="YOUR_REGISTRY.azurecr.io"
```

**Security Considerations:**
- File permissions set to 600 (owner read/write only)
- Ownership set to `runner:runner`
- Variables loaded via `source /opt/runner.env` in scripts

### AWS Secrets Manager Structure
Expected secret format in AWS Secrets Manager:
```json
{
  "registry_username": "your-username",
  "registry_password": "your-password"
}
```

## Workflow Usage Examples

### Basic Workflow
```yaml
name: Use Custom Runner

on:
  push:

permissions:
  id-token: write  # Required for OIDC authentication
  contents: read

jobs:
  build:
    runs-on: custcontain-ubu24-x64
    steps:
      - uses: actions/checkout@v5
      - name: Build
        run: |
          echo "Building on custom runner"
```

### Complete Container Job Example

Here's a complete example workflow using the custom container image with private registry authentication:

```yaml
name: Standard Linux Runner Workflow

on:
  push:
    paths:
      - '.github/workflows/standard-ubu-runner.yml'
  workflow_dispatch:

permissions:
  id-token: write  # Required for OIDC authentication
  contents: read   # Standard permission for checkout

jobs:
  test-with-container:
    runs-on: custcontain-ubu24-x64
    container:
      image: example-registry.azurecr.io/demo-image:latest
      env:
        NODE_ENV: test
      options: --user root
    steps:
      - name: Checkout code
        uses: actions/checkout@v5
      - name: Install dependencies
        run: echo "Hello world"
      - name: Run tests
        run: |
          echo "Running tests in private container"
          # Your test commands here
```

## Security Scanning

The pre-job hook includes workflow security scanning that:

1. Downloads workflow files for the current job
2. Scans for suspicious patterns
3. Creates GitHub issues for detected threats
4. Cancels execution if threats are found

### Scanned Patterns
```bash
SUSPICIOUS_PATTERNS=(
  "secrets\."
  "\${{.*secrets"
  "curl"
  "wget"
  "base64.*-d"
  "eval.*\$\("
  "nc -e"
  "\.decode\("
  "rm -rf /*"
)
```

## Troubleshooting

### Common Issues

1. **OIDC Token Failure**
   ```bash
   # Check if ACTIONS_ID_TOKEN_REQUEST_TOKEN is available
   echo "Token available: $([[ -n "$ACTIONS_ID_TOKEN_REQUEST_TOKEN" ]] && echo "Yes" || echo "No")"
   ```
   
   **Solution**: Ensure your workflow includes `permissions: id-token: write`

2. **AWS Role Assumption Failure**
   - Verify OIDC trust policy in AWS IAM role
   - Check repository permissions in GitHub
   - Ensure role ARN is correct in `runner.env`
   - Confirm the repository is allowed to assume the role

3. **Secret Retrieval Issues**
   - Verify IAM role has `secretsmanager:GetSecretValue` permission
   - Check secret ID and region configuration
   - Ensure secret contains required keys (`registry_username`, `registry_password`)

4. **Docker Login Failures**
   - Check registry URL format
   - Verify credentials in AWS Secrets Manager
   - Review Docker daemon accessibility
   - Ensure registry is accessible from the runner network

5. **Permission Denied Errors**
   - Verify the workflow has `permissions: id-token: write`
   - Check if the repository is configured for OIDC in AWS IAM trust policy
   - Ensure the runner has the custom container hooks installed

## Best Practices

1. **Secrets Management**
   - Never commit `runner.env` with real values
   - Use `.env.example` for documentation
   - Store actual values in GitHub Secrets and AWS Secrets Manager

2. **Access Control**
   - Limit IAM role permissions to minimum required
   - Use time-limited credentials (900 seconds default)
   - Regularly rotate registry credentials

3. **Monitoring**
   - Review security scanning results
   - Monitor failed authentication attempts
   - Track container pull activity

4. **Updates**
   - Keep runner-container-hooks up to date
   - Regularly update base images
   - Review and update security patterns

## Additional Resources

- [GitHub Actions OIDC Documentation](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect)
- [AWS IAM Roles for OIDC](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_create_for-idp_oidc.html)
- [Docker Registry Authentication](https://docs.docker.com/engine/reference/commandline/login/)