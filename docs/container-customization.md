# Custom Container Image Workflow Documentation

This document explains the [`image-ubu24-customcontainer.yml`](.github/workflows/image-ubu24-customcontainer.yml) workflow and how the container registry authentication works through the [`setup-registry-auth.sh`](runner-container-hooks/packages/docker/src/hooks/setup-registry-auth.sh) script.

## Overview

The [`image-ubu24-customcontainer.yml`](.github/workflows/image-ubu24-customcontainer.yml) workflow creates a specialized Ubuntu 24.04 runner image with advanced container capabilities. This image integrates GitHub's [customized container hooks preview feature](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/customize-containers), to provide secure, automated container registry authentication and enhanced Docker workflow support.

## Workflow Architecture

### Base Image Configuration
The workflow starts with a standard Ubuntu 24.04 setup:
- **Runner**: `image-generator-linux-24`
- **Snapshot**: `image-custcontain-ubu24-x64`
- **Pre-installed Software**: Git, Python 3.10, Docker, development tools (gcc, make, jq, curl, etc.)

### Key Workflow Steps

#### 1. Security and Environment Setup
```yaml
- name: Setup private key PEM file
  run: |
    echo "${{ secrets.PRIVATE_KEY_PEM }}" | sudo tee /opt/pre-script-auth.pem
    sudo chmod 644 /opt/pre-script-auth.pem

- name: Setup environment vars file for runner
  run: |
    sudo cp "${{ github.workspace }}/runner.env" /opt/runner.env
    sudo chown runner:runner /opt/runner.env
    sudo chmod 600 /opt/runner.env
```

**Security Features:**
- Private key stored securely in `/opt/pre-script-auth.pem`
- Environment variables from [`runner.env`](runner.env) copied with restricted permissions (600)
- Ownership set to `runner:runner` for proper access control

#### 2. Job Lifecycle Hooks
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

**Hook Integration:**
- **Pre-job Hook**: [`scripts/pre-script.sh`](scripts/pre-script.sh) - Performs security scanning of workflow files
- **Post-job Hook**: [`scripts/post-script.sh`](scripts/post-script.sh) - Cleanup operations
- Environment variables set in both system-wide (`/etc/environment`) and runner-specific locations

#### 3. Container Hooks Integration
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

**Container Hooks System:**
- Copies entire [`runner-container-hooks`](runner-container-hooks) package to `/opt/`
- Builds both `hooklib` (shared utilities) and `docker` (Docker-specific hooks) packages
- Sets `ACTIONS_RUNNER_CONTAINER_HOOKS` environment variable to enable container customization

## Container Hooks System Architecture

### Hook Integration Points
The [`runner-container-hooks`](runner-container-hooks) system provides four main lifecycle hooks:

1. **PrepareJob** ([`prepare-job.ts`](runner-container-hooks/packages/docker/src/hooks/prepare-job.ts))
   - Sets up containers and networks before job execution
   - **Automatically calls [`setup-registry-auth.sh`](runner-container-hooks/packages/docker/src/hooks/setup-registry-auth.sh)**
   - Creates Docker networks for container communication

2. **RunScriptStep** ([`run-script-step.ts`](runner-container-hooks/packages/docker/src/hooks/run-script-step.ts))
   - Handles script execution within containers
   - Manages environment variables and working directories

3. **RunContainerStep** ([`run-container-step.ts`](runner-container-hooks/packages/docker/src/hooks/run-container-step.ts))
   - Manages container-based workflow steps
   - Handles container builds and runs

4. **CleanupJob** ([`cleanup-job.ts`](runner-container-hooks/packages/docker/src/hooks/cleanup-job.ts))
   - Performs cleanup after job completion
   - Removes containers and networks

### Registry Authentication Integration

The [`setup-registry-auth.sh`](runner-container-hooks/packages/docker/src/hooks/setup-registry-auth.sh) script is automatically executed during the `PrepareJob` phase through this code in [`prepare-job.ts`](runner-container-hooks/packages/docker/src/hooks/prepare-job.ts):

```typescript
async function runSetupRegistryAuth(): Promise<void> {
  try {
    const scriptPath = path.resolve(__dirname, 'setup-registry-auth.sh')
    core.info('Running registry authentication setup...')
    
    execSync(`bash ${scriptPath}`, {
      stdio: 'inherit',
      env: {
        ...process.env,
        ACTIONS_ID_TOKEN_REQUEST_TOKEN: process.env.ACTIONS_ID_TOKEN_REQUEST_TOKEN,
        ACTIONS_ID_TOKEN_REQUEST_URL: process.env.ACTIONS_ID_TOKEN_REQUEST_URL
      }
    })
    
    core.info('Registry authentication setup completed successfully')
  } catch (error) {
    core.warning(`Failed to run registry authentication setup: ${error}`)
  }
}
```

## Registry Authentication Process

### Three-Phase Authentication Flow

The [`setup-registry-auth.sh`](runner-container-hooks/packages/docker/src/hooks/setup-registry-auth.sh) script implements a secure authentication process:

#### Phase 1: GitHub OIDC Authentication
```bash
# Request OIDC token from GitHub
OIDC_TOKEN=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=sts.amazonaws.com" 2>/dev/null | jq -r '.value')
```

**Process:**
- Uses GitHub's built-in OIDC provider
- Requests a token with AWS STS audience
- Token is scoped to the current workflow run
- Provides temporary, cryptographically signed credentials

#### Phase 2: AWS IAM Role Assumption
```bash
# Assume AWS IAM role using OIDC token
AWS_CREDS=$(aws sts assume-role-with-web-identity \
  --role-arn "$ROLE_ARN" \
  --role-session-name "GitHubActions-ACR-Hook" \
  --web-identity-token "$OIDC_TOKEN" \
  --duration-seconds 900 \
  --region "$AWS_REGION" \
  --output json 2>/dev/null)
```

**Process:**
- Exchanges OIDC token for temporary AWS credentials
- Uses federated identity trust relationship configured in AWS
- Credentials are valid for 15 minutes (900 seconds)
- No long-lived secrets stored in GitHub

#### Phase 3: Secret Retrieval and Docker Login
```bash
# Fetch container registry credentials from AWS Secrets Manager
ACR_SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_ID" \
  --query SecretString \
  --output text \
  --region "$AWS_REGION" 2>/dev/null)

# Extract and use credentials for Docker login
ACR_USERNAME=$(echo "$ACR_SECRET_JSON" | jq -r '.katiem0_actions_username' 2>/dev/null)
ACR_PASSWORD=$(echo "$ACR_SECRET_JSON" | jq -r '.katiem0_actions_secret' 2>/dev/null)

echo "$ACR_PASSWORD" | docker --config "$TEMP_DOCKER_CONFIG" login "$ACR_REGISTRY" \
  --username "$ACR_USERNAME" --password-stdin 2>/dev/null
```

**Process:**
- Retrieves actual registry credentials from AWS Secrets Manager
- Extracts username and password from JSON secret
- Performs Docker login using temporary config directory
- Copies authenticated config to default Docker location

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

### Environment Variables ([`runner.env`](runner.env))
The workflow uses centralized configuration:

```bash
# GitHub App credentials for workflow security scanning
APP_ID="1175942"
INSTALLATION_ID="62532994"
PRIVATE_KEY_PATH="/opt/pre-script-auth.pem"

# AWS IAM Role to assume for registry access
ROLE_ARN="arn:aws:iam::953721827634:role/katiem0-secrets-reader-role"
AWS_REGION="us-east-1"
SECRET_ID="katiem0-container-hooks"
ACR_REGISTRY="katiem0containertest.azurecr.io"
```

**Security Considerations:**
- File permissions set to 600 (owner read/write only)
- Ownership set to `runner:runner`
- Variables loaded via `source /opt/runner.env` in scripts

## Workflow Usage Examples

### Required OIDC Permissions

**IMPORTANT**: For OIDC authentication to work when using the custom container image built from this workflow, downstream workflows **must** include the following permissions:

```yaml
permissions:
  id-token: write  # Required for OIDC authentication
  contents: read   # Standard permission for checkout
```

Without the `id-token: write` permission, the GitHub OIDC token will not be available, and container registry authentication will fail.

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
      image: katiem0containertest.azurecr.io/demo-private-image:v3
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

### Container Job with Services

```yaml
jobs:
  container-with-services:
    runs-on: custcontain-ubu24-x64
    container:
      image: katiem0containertest.azurecr.io/my-custom-image:latest
      # Authentication is handled automatically by container hooks
    services:
      postgres:
        image: katiem0containertest.azurecr.io/postgres:14
        # Service containers also authenticated automatically
        env:
          POSTGRES_PASSWORD: postgres
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
    steps:
      - uses: actions/checkout@v4
      - name: Run application tests
        run: |
          echo "Container authentication handled seamlessly"
          # Your application tests here
```

### Multi-Container Workflow
```yaml
jobs:
  multi-container:
    runs-on: custcontain-ubu24-x64
    strategy:
      matrix:
        service: [api, web, worker]
    steps:
      - uses: actions/checkout@v4
      - name: Run tests in container
        uses: docker://katiem0containertest.azurecr.io/${{ matrix.service }}:latest
        with:
          args: npm test
      # All container pulls are automatically authenticated
```

## Security Benefits

1. **Zero Configuration**: No need to manually handle registry authentication in workflows
2. **Credential Isolation**: Credentials never appear in workflow logs or environment variables
3. **Temporary Access**: AWS credentials are short-lived and automatically cleaned up
4. **Audit Trail**: All access is logged through AWS CloudTrail and GitHub audit logs
5. **Principle of Least Privilege**: IAM role has minimal required permissions
6. **No Secrets in GitHub**: Only OIDC trust relationship, no long-lived credentials

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
   - Ensure role ARN is correct in [`runner.env`](runner.env)
   - Confirm the repository is allowed to assume the role

3. **Secret Retrieval Issues**
   - Verify IAM role has `secretsmanager:GetSecretValue` permission
   - Check secret ID and region configuration
   - Ensure secret contains required keys (`katiem0_actions_username`, `katiem0_actions_secret`)

4. **Docker Login Failures**
   - Check registry URL format
   - Verify credentials in AWS Secrets Manager
   - Review Docker daemon accessibility
   - Ensure registry is accessible from the runner network

5. **Permission Denied Errors**
   - Verify the workflow has `permissions: id-token: write`
   - Check if the repository is configured for OIDC in AWS IAM trust policy
   - Ensure the runner has the custom container hooks installed

### Debug Mode
To enable debug output, modify the script:
```bash
# Temporarily enable debug output (remove 2>/dev/null)
set -x  # Enable command tracing
```

### Verification Steps
To verify the custom container image is working correctly:

1. **Check Container Hooks**: Look for container hook logs in the runner output
2. **Verify OIDC Token**: Check if the OIDC token request succeeds
3. **Confirm AWS Access**: Verify AWS role assumption works
4. **Test Registry Access**: Ensure Docker login to private registry succeeds

This custom container image provides a production-ready solution for organizations using private container registries while maintaining the highest security standards through automated, temporary credential management and comprehensive audit trails.