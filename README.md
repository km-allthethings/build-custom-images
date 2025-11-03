# Build Custom GitHub Actions Runner Images

This repository contains workflows for building customized GitHub Actions runner images with different configurations. These custom images are designed to provide optimized, pre-configured environments for running GitHub Actions workflows.

## Available Images

### Ubuntu 24.04 Images

| Workflow | Image Name | Description | Configuration |
|----------|------------|-------------|---------------|
| [`image-ubu24-no-proxy.yml`](.github/workflows/image-ubu24-no-proxy.yml) | `image-custom-ubu24-x64` | Standard Ubuntu 24.04 image | No proxy settings, includes common development tools and Docker |
| [`image-ubu24-with-proxy.yml`](.github/workflows/image-ubu24-with-proxy.yml) | `proxy-image-ubu24-x64` | Ubuntu 24.04 with proxy configuration | Uses proxy settings via `/etc/environment` |
| [`image-ubu24-customcontainer.yml`](.github/workflows/image-ubu24-customcontainer.yml) | `image-custcontain-ubu24-x64` | Ubuntu 24.04 with container hooks | Includes customized runner container hooks for Docker registry authentication |

### Windows Server 2022 Images

| Workflow | Image Name | Description | Configuration |
|----------|------------|-------------|---------------|
| [`image-win2022-no-proxy.yml`](.github/workflows/image-win2022-no-proxy.yml) | `custom-img-win22-x64` | Standard Windows Server 2022 image | No proxy settings |
| Additional Windows workflows | `proxy-img-win22-x64` | Windows Server 2022 with proxy configuration | Configured with machine-level proxy settings |

## Features

### Pre-installed Software (Ubuntu)
- Git, curl, wget, vim, htop
- Python 3.10
- Docker and Docker Compose
- Development tools (gcc, make, zip/unzip)
- Common utilities (jq, net-tools)

### Container Hook Features (Custom Container Image)
The custom container image ([`image-ubu24-customcontainer.yml`](.github/workflows/image-ubu24-customcontainer.yml)) follows the [customized container](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/customize-containers) options as part of the Preview Feature, and includes:
- **Registry Authentication**: Automated Azure Container Registry (ACR) authentication using AWS Secrets Manager
- **Container Hooks**: Integration with [`runner-container-hooks`](runner-container-hooks) for enhanced container workflow support
- **Secure Credential Management**: Uses OIDC authentication with AWS IAM roles
- **Pre-loaded Images**: Includes `alpine:latest` and `quay.io/prometheus/prometheus:latest`

### Proxy Configuration
- **Ubuntu**: Proxy settings configured in `/etc/environment`
- **Windows**: Machine-level proxy settings and WinHTTP proxy configuration

### Pre/Post Job Hooks
Ubuntu images include:
- **Pre-job script** ([`scripts/pre-script.sh`](scripts/pre-script.sh)): Performs security checks on workflow files using GitHub App authentication
- **Post-job script** ([`scripts/post-script.sh`](scripts/post-script.sh)): Cleanup operations
- **Environment configuration**: Centralized config via [.env.example`](.env.example)

## Workflow Types

### Standard Images
- **No Proxy**: Basic image with development tools and Docker
- **With Proxy**: Includes proxy configuration for corporate environments

### Custom Container Images
- **Container Hooks**: Advanced container workflow support with registry authentication
- **AWS Integration**: Uses AWS Secrets Manager for secure credential storage
- **OIDC Authentication**: Leverages GitHub's OIDC provider for AWS access

## Usage

To use these custom images in your GitHub Actions workflows, specify the appropriate runner label:

```yaml
jobs:
  # Standard Ubuntu image
  standard-job:
    runs-on: image-generator-linux-24
    snapshot: image-custom-ubu24-x64
    
  # Ubuntu with proxy
  proxy-job:
    runs-on: image-generator-linux-24  
    snapshot: proxy-image-ubu24-x64
    
  # Ubuntu with container hooks
  container-job:
    runs-on: image-generator-linux-24
    snapshot: image-custcontain-ubu24-x64
    
  # Windows Server 2022
  windows-job:
    runs-on: image-generator-win2022
    snapshot: custom-img-win22-x64
```

## Security Features

### Container Registry Authentication
The custom container image includes secure authentication to Azure Container Registry:
- Uses AWS IAM role assumption via OIDC
- Credentials stored in AWS Secrets Manager
- Automatic Docker login configuration
- Secure credential cleanup after use

### Workflow Security Scanning
Pre-job hooks include security scanning that:
- Downloads and analyzes workflow files
- Scans for suspicious patterns and potential security risks
- Creates GitHub issues for detected threats
- Prevents execution of potentially malicious workflows

## Configuration

### Environment Variables
Key configuration is managed through [`.env.example`](.env.example):
- GitHub App credentials (`APP_ID`, `INSTALLATION_ID`)
- AWS IAM role (`ROLE_ARN`, `AWS_REGION`)
- Container registry settings (`ACR_REGISTRY`, `SECRET_ID`)

### Container Hooks
The [`runner-container-hooks`](runner-container-hooks) package provides:
- Docker container lifecycle management
- Registry authentication hooks
- Kubernetes container support (k8s package)
- Shared utilities (hooklib package)