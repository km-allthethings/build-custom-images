#!/bin/bash
set -eo pipefail # Exit on error, but don't print commands

# Function for GitHub Actions formatted debug logs
debug() {
  echo "::debug::$1"
}

# Function for GitHub Actions warnings
warning() {
  echo "::warning::$1"
}

# Function for GitHub Actions errors
error() {
  echo "::error::$1"
}

# Function for creating GitHub Actions groups (collapsible sections)
group() {
  echo "::group::$1"
}

# Function for ending a group
endgroup() {
  echo "::endgroup::"
}

# Start script with header
group "Environment information"
debug "Script starting execution at $(date)"
debug "GITHUB_REF: ${GITHUB_REF}"
debug "GITHUB_REPOSITORY: ${GITHUB_REPOSITORY}"
debug "GITHUB_RUN_ID: ${GITHUB_RUN_ID}"
debug "GITHUB_WORKFLOW_SHA: ${GITHUB_WORKFLOW_SHA}"
endgroup

# Define the output directory for downloaded workflow files
group "Setting up workflow directory"
WORKFLOW_DIR=".github/workflows"
mkdir -p "$WORKFLOW_DIR"
debug "Created workflow directory: $WORKFLOW_DIR"
endgroup

# GitHub App credentials
group "Configuring GitHub App authentication"
APP_ID="1175942"
INSTALLATION_ID="62532994" 
PRIVATE_KEY_PATH="/opt/pre-script-auth.pem"
debug "Using APP_ID: $APP_ID, INSTALLATION_ID: $INSTALLATION_ID"

# Check if private key exists
if [ ! -f "$PRIVATE_KEY_PATH" ]; then
  error "Private key file not found at $PRIVATE_KEY_PATH"
  exit 1
fi
debug "Private key exists at $PRIVATE_KEY_PATH with permissions: $(ls -la $PRIVATE_KEY_PATH)"
endgroup

# Create JWT header and payload
group "Generating JWT token"
now=$(date +%s)
iat=$((${now} - 60))
exp=$((${now} + 600))
debug "JWT timestamps - iat: $iat, exp: $exp"

b64enc() { openssl base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n'; }

# Verify the JWT creation components step by step
header_json='{
    "typ":"JWT",
    "alg":"RS256"
}'
header=$(echo -n "${header_json}" | b64enc)
debug "JWT header encoded (first 10 chars): ${header:0:10}..."

payload_json="{
    \"iat\":${iat},
    \"exp\":${exp},
    \"iss\":\"${APP_ID}\"
}"
payload=$(echo -n "${payload_json}" | b64enc)
debug "JWT payload encoded (first 10 chars): ${payload:0:10}..."

header_payload="${header}.${payload}"
debug "JWT header.payload constructed"

# Verify that OpenSSL can read the key
if ! openssl rsa -in "$PRIVATE_KEY_PATH" -check -noout > /dev/null 2>&1; then
  error "OpenSSL cannot read private key. Check file format and permissions."
  exit 1
fi
debug "Private key is readable by OpenSSL"

# Sign the JWT
if ! signature=$(openssl dgst -sha256 -sign "$PRIVATE_KEY_PATH" <(echo -n "${header_payload}") | b64enc); then
  error "Failed to sign JWT"
  exit 1
fi
debug "JWT signature generated successfully"

JWT="${header_payload}.${signature}"
debug "JWT token has $(echo -n "$JWT" | tr -cd '.' | wc -c) dots (expected: 2)"
endgroup

# Get installation token using JWT
group "Getting GitHub App installation token"
debug "Requesting installation token..."
response=$(curl --request POST -sL \
  -H "Authorization: Bearer $JWT" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app/installations/$INSTALLATION_ID/access_tokens")

# Check for errors in the response
if echo "$response" | grep -q "message"; then
  error_message=$(echo "$response" | jq -r '.message // "Unknown error"')
  error "GitHub API returned error: $error_message"
  debug "Full response: $(echo "$response" | jq '.')"
  exit 1
fi

AUTH_TOKEN=$(echo "$response" | jq -r '.token')
if [ -z "$AUTH_TOKEN" ] || [ "$AUTH_TOKEN" == "null" ]; then
  error "Failed to get installation token"
  debug "API Response: $(echo "$response" | jq '.')"
  exit 1
fi
debug "Installation token obtained successfully"
endgroup

# Get workflow run information
group "Getting workflow run information"
debug "Fetching workflow run details..."
response=$(curl -sL \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${AUTH_TOKEN}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}")

# Verify the API response contains the expected data
if ! workflow_path=$(echo "$response" | jq -r '.path'); then
  error "Failed to get workflow path from API response"
  debug "API Response: $(echo "$response" | jq '.')"
  exit 1
fi
debug "Workflow path: $workflow_path"

referenced_workflows=$(echo "$response" | jq '.referenced_workflows')
debug "Referenced workflows: $(echo "$referenced_workflows" | jq '.')"
endgroup

# Process files to download
group "Processing workflow files"
workflow_file="${workflow_path%%@*}"
debug "Primary workflow file: ${workflow_file}"

# Download the primary workflow file into WORKFLOW_DIR
debug "Downloading primary workflow file..."
http_code=$(curl -sL -w "%{http_code}" \
  -H "Accept: application/vnd.github.raw+json" \
  -H "Authorization: Bearer ${AUTH_TOKEN}" \
  "https://api.github.com/repos/${GITHUB_REPOSITORY}/contents/${workflow_file}?ref=${GITHUB_WORKFLOW_SHA}" \
  -o "$WORKFLOW_DIR/$(basename "$workflow_file)")

if [ "$http_code" != "200" ]; then
  error "Failed to download primary workflow file. HTTP status: $http_code"
  exit 1
fi
debug "Primary workflow file downloaded to: $WORKFLOW_DIR/$(basename "$workflow_file")"

mapping_json="{}"
mapping_json=$(jq --arg file "$(basename "$workflow_file")" --arg repo "$GITHUB_REPOSITORY" '. + {($file): $repo}' <<< "$mapping_json")
debug "Updated mapping JSON: $(echo "$mapping_json" | jq '.')"

# Download additional files specified in referenced_workflows (if any)
workflow_count=$(echo "$referenced_workflows" | jq 'length')
debug "Found $workflow_count referenced workflows"

if [ "$workflow_count" -eq 0 ]; then
  debug "No referenced workflows to download."
else
  for row in $(echo "$referenced_workflows" | jq -c '.[]'); do
    full_path=$(echo "$row" | jq -r '.path')
    GITHUB_LOCATION="${full_path%%/.github*}"
    workflow_path="${full_path%%@*}"
    WF_PART="${workflow_path#${GITHUB_LOCATION}/.github/}"
    referenced_workflow_path=".github/${WF_PART}"
    debug "Processing workflow: $referenced_workflow_path from $GITHUB_LOCATION"
    
    file_ref=$(echo "$row" | jq -r '.ref // empty')
    debug "Using ref: $file_ref"
    
    mapping_json=$(jq --arg file "$(basename "${referenced_workflow_path}")" --arg loc "$GITHUB_LOCATION" '. + {($file): $loc}' <<< "$mapping_json")
    
    http_code=$(curl -sL -w "%{http_code}" \
      -H "Accept: application/vnd.github.raw+json" \
      -H "Authorization: Bearer ${AUTH_TOKEN}" \
      "https://api.github.com/repos/${GITHUB_LOCATION}/contents/${referenced_workflow_path}?ref=${file_ref}" \
      -o "${WORKFLOW_DIR}/$(basename "${referenced_workflow_path}")")
    
    if [ "$http_code" != "200" ]; then
      error "Failed to download referenced workflow: ${referenced_workflow_path}. HTTP status: $http_code"
    else
      debug "Downloaded referenced workflow to ${WORKFLOW_DIR}/$(basename "${referenced_workflow_path}")"
    fi
  done
fi
endgroup

# Security check
group "Performing security check on workflow files"
SUSPICIOUS_PATTERNS=(
  "curl"
  "wget"
  "base64.*-d"
  "eval.*\$\("
  "nc -e"
  "\.decode\("
  "rm -rf /*"
)

detected_patterns=()
debug "Checking for ${#SUSPICIOUS_PATTERNS[@]} suspicious patterns"

while read -r file; do
  debug "Scanning file: $file"
  mapping_value=$(jq -r --arg key "$(basename "$file")" '.[$key]' <<< "$mapping_json")
  
  for pattern in "${SUSPICIOUS_PATTERNS[@]}"; do
    if grep -q -E "$pattern" "$file"; then
      warning "Suspicious pattern '$pattern' found in $file (from: $mapping_value)"
      matching_lines=$(grep -n -E "$pattern" "$file" | sed "s/^/Line /")
      debug "Matching lines: $matching_lines"
      detected_patterns+=("Pattern '$pattern' found in '$file' (from: '$mapping_value')")
    fi
  done
done < <(find "$WORKFLOW_DIR" -type f)
debug "Security check complete with ${#detected_patterns[@]} detected patterns"
endgroup

# Create issue if patterns detected
if [ ${#detected_patterns[@]} -gt 0 ]; then
  group "Creating security alert issue"
  debug "Creating issue for ${#detected_patterns[@]} detected patterns"
  
  ref="${GITHUB_REF##*/}"
  title="Security Alert on \`${ref}\`: Suspicious patterns found in workflow files"
  
  issue_body="The following suspicious patterns were detected:\n\n"
  for det in "${detected_patterns[@]}"; do
    issue_body+="- $det\n"
  done
  issue_body+="\nPlease review immediately."
  
  issue_json=$(jq -n --arg title "$title" --arg body "$issue_body" \
    '{title: $title, body: $body, labels: ["bug"], assignees: ["katiem0"]}')
  
  debug "Issue JSON: $(echo "$issue_json" | jq '.')"
  
  response=$(curl -s -X POST \
    -H "Authorization: Bearer ${AUTH_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$issue_json" \
    "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues")
  
  if echo "$response" | grep -q "number"; then
    issue_number=$(echo "$response" | jq '.number')
    debug "Issue #$issue_number created successfully"
  else
    error "Failed to create issue"
    debug "API response: $(echo "$response" | jq '.')"
  fi
  
  error "Suspicious patterns detected. See issue for details."
  endgroup
  exit 1
fi

echo "Security check passed. The workflow files appear safe."