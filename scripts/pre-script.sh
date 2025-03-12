#!/bin/bash
echo "Workflow running on ref: ${GITHUB_REF}"

# Define the output directory for downloaded workflow files
WORKFLOW_DIR=".github/workflows"
mkdir -p "$WORKFLOW_DIR"

# GitHub App credentials
APP_ID="1175942"
INSTALLATION_ID="62532994" 
PRIVATE_KEY_PATH="/root/actions-runner/auth/pre-script-auth.pem"

# Generate JWT for GitHub App authentication
generate_jwt() {
  # Create JWT header and payload
  header='{"alg":"RS256","typ":"JWT"}'
  now=$(date +%s)
  expiry=$((now + 600))  # 10 minutes
  payload="{\"iat\":$now,\"exp\":$expiry,\"iss\":$APP_ID}"
  
  # Base64 encode header and payload
  b64_header=$(echo -n "$header" | base64 | tr '+/' '-_' | tr -d '=')
  b64_payload=$(echo -n "$payload" | base64 | tr '+/' '-_' | tr -d '=')
  
  # Sign with private key
  signature=$(echo -n "$b64_header.$b64_payload" | openssl dgst -sha256 -sign "$PRIVATE_KEY_PATH" | base64 | tr '+/' '-_' | tr -d '=')
  
  # Combine to form JWT
  echo "$b64_header.$b64_payload.$signature"
}

# Get installation token using JWT
get_installation_token() {
  jwt=$(generate_jwt)
  response=$(curl -s -X POST \
    -H "Authorization: Bearer $jwt" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/app/installations/$INSTALLATION_ID/access_tokens")
  
  echo "$response" | jq -r '.token'
}

# Get token and use it for API calls
AUTH_TOKEN=$(get_installation_token)

# (Assuming response from the actions runs API was already obtained)
response=$(curl -s -L \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${AUTH_TOKEN}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}")

# Extract the referenced_workflows JSON object (assumed to be an array of objects)
workflow_path=$(echo "$response" | jq -r '.path')
referenced_workflows=$(echo "$response" | jq '.referenced_workflows')
echo "Referenced workflows object: $referenced_workflows"

# Strip off everything after the '@' from GITHUB_WORKFLOW_REF to get the workflow file path
workflow_file="${workflow_path%%@*}"
echo "Primary workflow file: ${workflow_file}"

# Download the primary workflow file into WORKFLOW_DIR
curl -L \
  -H "Accept: application/vnd.github.raw+json" \
  -H "Authorization: Bearer ${AUTH_TOKEN}" \
  "https://api.github.com/repos/${GITHUB_REPOSITORY}/contents/${workflow_file}?ref=${GITHUB_WORKFLOW_SHA}" \
  -o "$WORKFLOW_DIR/$(basename "$workflow_file")"

mapping_json="{}"
mapping_json=$(jq --arg file "$(basename "$workflow_file")" --arg repo "$GITHUB_REPOSITORY" '. + {($file): $repo}' <<< "$mapping_json")

# Download additional files specified in referenced_workflows (if any)
workflow_count=$(echo "$referenced_workflows" | jq 'length')
if [ "$workflow_count" -eq 0 ]; then
  echo "No referenced workflows to download."
else
  for row in $(echo "$referenced_workflows" | jq -c '.[]'); do
      full_path=$(echo "$row" | jq -r '.path')
      GITHUB_LOCATION="${full_path%%/.github*}"
      workflow_path="${full_path%%@*}"
      WF_PART="${workflow_path#${GITHUB_LOCATION}/.github/}"
      referenced_workflow_path=".github/${WF_PART}"
      echo "Workflow path: $workflow_path"
      file_ref=$(echo "$row" | jq -r '.ref // empty')
      mapping_json=$(jq --arg file "$(basename "${referenced_workflow_path}")" --arg loc "$GITHUB_LOCATION" '. + {($file): $loc}' <<< "$mapping_json")

      echo "Downloading referenced file: $workflow_path (ref: $file_ref)"
      curl -L \
        -H "Accept: application/vnd.github.raw+json" \
        -H "Authorization: Bearer ${AUTH_TOKEN}" \
        "https://api.github.com/repos/${GITHUB_LOCATION}/contents/${referenced_workflow_path}?ref=${file_ref}" \
        -o "${WORKFLOW_DIR}/$(basename "${referenced_workflow_path}")"
  done
fi

echo "Download of workflow files complete."

# ----- Security Check on Downloaded Workflows -----
# Define suspicious patterns to look for in workflow files
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

# Debug: list files in the directory to verify they exist
echo "Files in $WORKFLOW_DIR:"
ls -la "$WORKFLOW_DIR"

# Process each file individually
while read -r file; do
  echo "Checking file: $file"
  
  # Get the mapping value for this file from mapping_json using its basename
  mapping_value=$(jq -r --arg key "$(basename "$file")" '.[$key]' <<< "$mapping_json")
  
  for pattern in "${SUSPICIOUS_PATTERNS[@]}"; do
    if grep -q -E "$pattern" "$file"; then
      echo "::error::Potential malicious pattern found: $pattern in $file"
      
      # Get matching lines for context
      matching_lines=$(grep -n -E "$pattern" "$file" | sed "s/^/Line /")
      
      # Build detection string including the mapping value
      detection="\`$pattern\` found in \`$file\` (from: \`$mapping_value\`)"
      
      detected_patterns+=("$detection")
    fi
  done
done < <(find "$WORKFLOW_DIR" -type f)

echo "Completed security scan of all files"
echo "Number of detections: ${#detected_patterns[@]}"

if [ ${#detected_patterns[@]} -gt 0 ]; then
    echo "Found ${#detected_patterns[@]} suspicious patterns"
    ref="${GITHUB_REF##*/}"
    title="Security Alert on \`${ref}\`: Suspicious patterns found in workflow files"
    
    issue_body=$(cat <<EOF
The following potential malicious patterns were detected in the workflow files:

$(for det in "${detected_patterns[@]}"; do
    echo "- $det"
done)

Please review immediately.
EOF
    )
    
    issue_json=$(jq -n --arg title "$title" --arg body "$issue_body" \
      '{title: $title, body: $body, labels: ["bug"], assignees: ["katiem0"]}')

    echo "Creating GitHub issue with the following payload:"
    echo "$issue_json" | jq .

    curl -s -X POST -H "Accept: application/vnd.github.v3+json" \
      -H "Authorization: Bearer ${AUTH_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$issue_json" \
      "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues" > /dev/null 2>&1
                  
    echo "Cancelling workflow for security reasons."
    exit 1
fi

echo "Security check passed. The workflow files appear safe."