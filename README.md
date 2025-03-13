# build-custom-images

## Custom Image Pre-build Security Script Documentation
### Overview
This script implements a security scanning mechanism that executes before GitHub Actions workflows run on our custom image builders. It authenticates as a GitHub App, downloads workflow files, scans them for potentially malicious patterns, and creates security issues when suspicious content is detected.

### Key Components

#### Authentication Flow

1. **GitHub App Authentication**: The script uses a two-step authentication process:
  - First, it generates a JWT (JSON Web Token) signed with a private key
  - Then exchanges this JWT for an installation access token
2. **Token Generation**:
  - Creates a standard JWT with header, payload, and signature
  - Header specifies RS256 signing algorithm
  - Payload includes timestamps and the GitHub App ID
  - Signs using the private key stored at `/opt/pre-script-auth.pem` on custom image of runner

#### Workflow File Processing

1. **Primary Workflow Download**:
  - Fetches information about the current workflow run using GitHub's API
  - Extracts the primary workflow file path and downloads it
2. **Referenced Workflows Handling**:
  - Identifies any referenced/reusable workflows from other repositories
  - Maps each workflow file to its source repository for traceability
  - Downloads all referenced workflow files for security scanning

#### Security Scanning

1. **Pattern Detection**:
  - Scans all downloaded workflow files for suspicious patterns including:
    - Command execution tools (`curl`, `wget`)
    - Encoded command execution (`base64 -d`)
    - Potentially dangerous evaluations (`eval`)
    - Destructive filesystem operations (`rm -rf /*`)
    - Other risky patterns
2. **Security Response**:
  - If suspicious patterns are detected, creates a GitHub issue in the repository
  - Issue includes detailed information about detected patterns, file locations, and source repositories
  - Automatically assigns appropriate team members for review
  - Applies bug/security labels for tracking
  - Cancels the workflow run to prevent potential security risks

### Benefits
- **Supply Chain Security**: Prevents execution of potentially compromised workflow files
- **Cross-Repository Protection**: Extends security scanning to referenced workflows from other repositories
- **Automated Response**: Creates actionable security alerts without manual intervention
- **Auditability**: Maintains detailed records of detected security concerns for compliance purposes

### Implementation Details
The script is integrated as a pre-run hook in our custom images and executed automatically before any workflow runs, providing seamless security scanning without developer intervention.
