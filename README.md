# Build Custom GitHub Actions Runner Images

This repository contains workflows for building customized GitHub Actions runner images with different configurations. These custom images are designed to provide optimized, pre-configured environments for running GitHub Actions workflows.

## Available Images

### Ubuntu 24.04 Images

| Image Name | Description | Configuration |
|------------|-------------|---------------|
| `image-custom-ubu24-x64` | Standard Ubuntu 24.04 image | No proxy settings, includes common development tools and Docker |
| `proxy-image-ubu24-x64` | Ubuntu 24.04 with proxy configuration | Uses proxy settings via `/etc/environment` |

### Windows Server 2022 Images

| Image Name | Description | Configuration |
|------------|-------------|---------------|
| `custom-img-win22-x64` | Standard Windows Server 2022 image | No proxy settings |
| `proxy-img-win22-x64` | Windows Server 2022 with proxy configuration | Configured with machine-level proxy settings |

## Features

### Pre-installed Software (Ubuntu)
- Git, curl, wget, vim
- Python 3.10
- Docker and Docker Compose
- Development tools (gcc, make, etc.)
- Common utilities (jq, htop, zip/unzip, net-tools)

### Proxy Configuration
- **Ubuntu**: Proxy settings configured in `/etc/environment`
- **Windows**: Machine-level proxy settings and WinHTTP proxy configuration

### Pre/Post Job Hooks
Both Ubuntu images include:
- Pre-job script that performs security checks on workflow files
- Post-job script for cleanup operations

## Usage

To use these custom images in your GitHub Actions workflows, specify the appropriate runner label:

```yaml
jobs:
  my-job:
    runs-on: image-generator-linux-24  # For Ubuntu 24.04
    # OR
    runs-on: image-generator-win2022   # For Windows Server 2022
    # With appropriate snapshot setting# build-custom-images